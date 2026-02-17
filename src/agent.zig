const std = @import("std");
const config_mod = @import("config.zig");
const provider_mod = @import("provider.zig");
const memory_mod = @import("memory.zig");
const tools_mod = @import("tools.zig");
const security_mod = @import("security.zig");

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
    user_message: []const u8,
) !void {
    var stdout = std.io.getStdOut().writer();

    const system_prompt = "You are BareClaw, a fast, bear-themed AI assistant.";

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
        const effective_user = if (context.items.len == 0)
            user_message
        else blk: {
            var msg = std.ArrayList(u8).init(allocator);
            errdefer msg.deinit();
            try msg.appendSlice(user_message);
            try msg.appendSlice("\n\n[Tool results so far]\n");
            try msg.appendSlice(context.items);
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
            reply,
            &context,
        );

        if (!dispatched) {
            // No tool calls – this is the final text reply.
            try memory.store("last_message", user_message);
            try stdout.print("{s}\n", .{reply});
            return;
        }

        // Tool calls were dispatched; loop back to give the model the results.
    }

    // Hit round limit – just print whatever we have.
    try stdout.print("(agent reached max tool-call rounds)\n", .{});
}

/// Parse all tool_calls from response_json, execute each one using a proper
/// ToolContext (with real policy and memory), and append results to `context`.
/// Returns true if at least one tool call was found and dispatched.
fn dispatchAllToolCalls(
    allocator: std.mem.Allocator,
    tools: []const tools_mod.Tool,
    policy: *security_mod.SecurityPolicy,
    memory: *memory_mod.MemoryBackend,
    response_json: []const u8,
    context: *std.ArrayList(u8),
) !bool {
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
    };

    for (tool_calls.items) |call| {
        const func = call.object.get("function") orelse continue;
        const name_val = func.object.get("name") orelse continue;
        const args_val = func.object.get("arguments") orelse continue;

        const name = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        const args_json = switch (args_val) {
            .string => |s| s,
            else => "{}",
        };

        // Find and execute the matching tool.
        for (tools) |tool| {
            if (!std.mem.eql(u8, tool.name, name)) continue;

            const result = tool.executeFn(&ctx, args_json) catch |err| blk: {
                const msg = try std.fmt.allocPrint(allocator, "tool error: {}", .{err});
                defer allocator.free(msg);
                break :blk tools_mod.ToolResult{ .success = false, .output = msg };
            };

            // Append result to context buffer.
            const status = if (result.success) "ok" else "error";
            try context.writer().print(
                "[{s}] {s}: {s}\n",
                .{ status, name, result.output },
            );

            // Free output if it was heap-allocated (tools return slices that
            // may be either static or allocated; we dupe to be safe).
            break;
        }
    }

    return true;
}

