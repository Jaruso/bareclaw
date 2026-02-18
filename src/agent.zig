const std = @import("std");
const config_mod = @import("config.zig");
const provider_mod = @import("provider.zig");
const memory_mod = @import("memory.zig");
const tools_mod = @import("tools.zig");
const security_mod = @import("security.zig");
const mcp_mod = @import("mcp_client.zig");

/// Maximum number of back-and-forth tool-call rounds before we stop and
/// return the last assistant message. Prevents runaway loops.
const MAX_TOOL_ROUNDS: usize = 8;

pub fn runAgentOnce(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
) !void {
    var stdout = std.io.getStdOut().writer();
    try runAgentOnceToWriter(allocator, cfg, provider, memory, tools, policy, mcp_pool, user_message, &stdout);
}

/// Like runAgentOnce but captures the final reply into an ArrayList instead of
/// printing it, so callers (e.g. Discord channel) can forward the text elsewhere.
/// The caller owns the returned slice — free it with allocator.free().
pub fn runAgentOnceCaptured(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    var writer = buf.writer();
    try runAgentOnceToWriter(allocator, cfg, provider, memory, tools, policy, mcp_pool, user_message, &writer);
    return buf.toOwnedSlice();
}

fn runAgentOnceToWriter(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: provider_mod.AnyProvider,
    memory: *memory_mod.MemoryBackend,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    user_message: []const u8,
    out: anytype,
) !void {
    // Build the system prompt, injecting a tool manifest when tools are available.
    // This tells the LLM what tools it can call and the exact JSON format to use,
    // so it emits {"tool_calls":[{"function":{"name":"...","arguments":"..."}}]}
    // which dispatchAllToolCalls() can parse.
    var system_buf = std.ArrayList(u8).init(allocator);
    defer system_buf.deinit();
    const sw = system_buf.writer();

    try sw.writeAll("You are BareClaw, a fast, bear-themed AI assistant.");

    if (tools.len > 0) {
        try sw.writeAll(
            "\n\nYou have access to the following tools. " ++
            "When you need to use a tool, respond with ONLY a JSON object in this exact format " ++
            "(no markdown, no other text before or after the JSON):\n" ++
            "{\"tool_calls\":[{\"function\":\"TOOL_NAME\",\"arguments\":{}}]}\n\n" ++
            "Available tools:\n",
        );
        for (tools) |tool| {
            try sw.print("- {s}", .{tool.name});
            if (tool.description.len > 0) {
                try sw.print(": {s}", .{tool.description});
            }
            try sw.writeByte('\n');
        }
        try sw.writeAll(
            "\nAfter receiving tool results, respond with the final answer as plain text.\n" ++
            "Only use tools when they are needed to answer the question.",
        );
    }

    const system_prompt = system_buf.items;

    // --- Tool-calling loop ---------------------------------------------------
    // Each iteration:
    //   1. Send current user message to the provider.
    //   2. If the response contains tool_calls, dispatch each call, collect
    //      results, and feed them back as a follow-up user message.
    //   3. Otherwise print the final text reply and stop.
    // ------------------------------------------------------------------------

    // We accumulate tool results into a growing "context" string that gets
    // prepended to subsequent user turns so the model can see prior results.
    var context = std.ArrayList(u8).init(allocator);
    defer context.deinit();

    var round: usize = 0;
    while (round < MAX_TOOL_ROUNDS) : (round += 1) {
        // Build the message for this round: original user text + any prior tool results.
        // On rounds after the first, explicitly instruct the model to summarize in
        // plain text — not to emit more tool_calls JSON.
        const effective_user = if (context.items.len == 0)
            user_message
        else blk: {
            var msg = std.ArrayList(u8).init(allocator);
            errdefer msg.deinit();
            try msg.appendSlice(user_message);
            try msg.appendSlice("\n\n[Tool results]\n");
            try msg.appendSlice(context.items);
            try msg.appendSlice(
                "\n[Instructions] The tool has returned results above. " ++
                "Now respond to the user's original question in plain, friendly text. " ++
                "Do NOT output any JSON or tool_calls. Summarize the results clearly.",
            );
            break :blk try msg.toOwnedSlice();
        };
        const owns_effective = context.items.len > 0;
        defer if (owns_effective) allocator.free(effective_user);

        const reply = try provider.chatOnce(
            system_prompt,
            effective_user,
            cfg.default_model,
            0.7,
        );
        defer allocator.free(reply);

        // Try to dispatch tool calls from this reply.
        const dispatched = try dispatchAllToolCalls(
            allocator,
            tools,
            policy,
            memory,
            mcp_pool,
            reply,
            &context,
        );

        if (!dispatched) {
            // No tool calls – this is the final text reply.
            try memory.store("last_message", user_message);
            try out.print("{s}\n", .{reply});
            return;
        }

        // Tool calls were dispatched; loop back to give the model the results.
    }

    // Hit round limit – just print whatever we have.
    try out.print("(agent reached max tool-call rounds)\n", .{});
}

// ── T1-2: Context budget ──────────────────────────────────────────────────────
// Maximum accumulated tool-result characters before we truncate oldest entries.
// Keeps context well within typical model context windows.
const MAX_CONTEXT_CHARS: usize = 12_000;
// Exported for tests in root.zig.
pub const MAX_CONTEXT_CHARS_EXPORTED: usize = MAX_CONTEXT_CHARS;

// ── T1-1: Robust JSON extraction ─────────────────────────────────────────────
//
// Models frequently wrap their JSON in prose or markdown fences, e.g.:
//   "Sure! Here is the tool call:\n```json\n{...}\n```"
// This function strips fences and extracts the first top-level {...} block
// so dispatchAllToolCalls() can parse it even when the model misbehaves.
//
// Returns a slice into `input` (no allocation). Returns null if no JSON
// object is found.
fn extractJsonObject(input: []const u8) ?[]const u8 {
    // Strip markdown code fences (```json ... ``` or ``` ... ```).
    var src = input;
    if (std.mem.indexOf(u8, src, "```")) |fence_start| {
        const after_fence = fence_start + 3;
        // Skip optional language tag on the same line (e.g. "json\n").
        const newline = std.mem.indexOfScalarPos(u8, src, after_fence, '\n') orelse after_fence;
        const content_start = newline + 1;
        if (std.mem.lastIndexOf(u8, src, "```")) |fence_end| {
            if (fence_end > content_start) {
                src = std.mem.trim(u8, src[content_start..fence_end], " \t\r\n");
            }
        }
    }

    // Find the first '{' and its matching '}'.
    const obj_start = std.mem.indexOfScalar(u8, src, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escape_next = false;
    var i = obj_start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape_next) { escape_next = false; continue; }
        if (c == '\\' and in_string) { escape_next = true; continue; }
        if (c == '"') { in_string = !in_string; continue; }
        if (in_string) continue;
        if (c == '{') { depth += 1; }
        else if (c == '}') {
            depth -= 1;
            if (depth == 0) return src[obj_start .. i + 1];
        }
    }
    return null;
}

/// Parse all tool_calls from response_json, execute each one using a proper
/// ToolContext (with real policy and memory), and append results to `context`.
/// Returns true if at least one tool call was found and dispatched.
fn dispatchAllToolCalls(
    allocator: std.mem.Allocator,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    memory: *memory_mod.MemoryBackend,
    mcp_pool: ?*mcp_mod.McpSessionPool,
    response_raw: []const u8,
    context: *std.ArrayList(u8),
) !bool {
    // T1-1: Extract a JSON object from the response, tolerating prose wrapping.
    const response_json = extractJsonObject(response_raw) orelse return false;

    // The response may be plain text (no JSON) – parse gracefully.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch
        return false;
    defer parsed.deinit();

    const tool_calls_val = parsed.value.object.get("tool_calls") orelse return false;
    const tool_calls = switch (tool_calls_val) {
        .array => |a| a,
        else => return false,
    };
    if (tool_calls.items.len == 0) return false;

    var ctx = tools_mod.ToolContext{
        .allocator = allocator,
        .policy    = policy,
        .memory    = memory,
        .mcp_pool  = mcp_pool,
    };

    for (tool_calls.items) |call| {
        if (call != .object) continue;

        // Support two formats LLMs commonly emit:
        //
        // Format A (OpenAI-style, what we ask for):
        //   {"function": {"name": "tool_name", "arguments": "{}"}}
        //
        // Format B (flat, what Ollama/llama3.2 often produces):
        //   {"function": "tool_name", "arguments": {}}
        //
        const name: []const u8 = blk: {
            const func_val = call.object.get("function") orelse continue;
            switch (func_val) {
                // Format A: function is an object with a "name" key
                .object => {
                    const n = func_val.object.get("name") orelse continue;
                    break :blk switch (n) { .string => |s| s, else => continue };
                },
                // Format B: function is the name string directly
                .string => |s| break :blk s,
                else => continue,
            }
        };

        // Arguments: check inside the function object first (Format A),
        // then fall back to a top-level "arguments" key (Format B).
        const args_json: []const u8 = blk: {
            // Format A: {"function": {"name": "...", "arguments": "..."}}
            if (call.object.get("function")) |func_val| {
                if (func_val == .object) {
                    if (func_val.object.get("arguments")) |av| {
                        switch (av) {
                            .string => |s| break :blk s,
                            // arguments is already an object — serialize it back
                            else => break :blk "{}",
                        }
                    }
                }
            }
            // Format B: top-level "arguments" key
            if (call.object.get("arguments")) |av| {
                switch (av) {
                    .string => |s| break :blk s,
                    else => break :blk "{}",
                }
            }
            break :blk "{}";
        };

        // Find and execute the matching tool.
        for (tools) |tool| {
            if (!std.mem.eql(u8, tool.name, name)) continue;

            // For MCP proxy tools, set the per-tool metadata in context so
            // toolMcpProxy knows which server and tool to call.
            ctx.mcp_current_meta = tool.user_data;
            defer ctx.mcp_current_meta = null;

            const result = tool.executeFn(&ctx, args_json) catch |err| blk: {
                const msg = try std.fmt.allocPrint(allocator, "tool error: {}", .{err});
                defer allocator.free(msg);
                break :blk tools_mod.ToolResult{ .success = false, .output = msg };
            };

            // Append result to context buffer.
            const status = if (result.success) "ok" else "error";
            const entry = try std.fmt.allocPrint(
                allocator,
                "[{s}] {s}: {s}\n",
                .{ status, name, result.output },
            );
            defer allocator.free(entry);

            // T1-2: Enforce context budget. If adding this entry would exceed
            // MAX_CONTEXT_CHARS, drop oldest entries (from the front) until it fits.
            if (context.items.len + entry.len > MAX_CONTEXT_CHARS) {
                const needed = (context.items.len + entry.len) -| MAX_CONTEXT_CHARS;
                // Find a newline boundary so we don't cut mid-line.
                const cut = if (std.mem.indexOfPos(u8, context.items, needed, "\n")) |nl|
                    nl + 1
                else
                    @min(needed, context.items.len);
                // Shift remaining content to the front.
                const remaining = context.items.len - cut;
                std.mem.copyForwards(u8, context.items[0..remaining], context.items[cut..]);
                context.shrinkRetainingCapacity(remaining);
                // Prepend a truncation marker so the model knows history was dropped.
                const marker = "[... earlier tool results truncated due to context budget ...]\n";
                try context.insertSlice(0, marker);
            }
            try context.appendSlice(entry);

            break;
        }
    }

    return true;
}

