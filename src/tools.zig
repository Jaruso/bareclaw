const std = @import("std");
const security_mod = @import("security.zig");
const memory_mod = @import("memory.zig");
const mcp_mod = @import("mcp_client.zig");

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
};

pub const Tool = struct {
    name:        []const u8,
    description: []const u8 = "", // human/LLM-readable description; "" = no description
    executeFn:   *const fn (ctx: *ToolContext, args_json: []const u8) anyerror!ToolResult,
    /// Optional per-tool metadata (e.g. for MCP proxy tools). Owned by the tool registry.
    user_data: ?*anyopaque = null,
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    policy: *security_mod.SecurityPolicy,
    memory: *memory_mod.MemoryBackend,
    /// Optional MCP session pool, shared across all MCP proxy tool calls in a session.
    mcp_pool: ?*mcp_mod.McpSessionPool = null,
    /// Set by agent.zig dispatch loop to point at the current tool's McpProxyMeta
    /// before calling toolMcpProxy. Only valid during an MCP proxy tool call.
    mcp_current_meta: ?*anyopaque = null,
};

// ── helpers ──────────────────────────────────────────────────────────────────

/// Extract a string field from a parsed JSON object. Returns null if missing
/// or not a string. The returned slice is valid for the lifetime of `parsed`.
fn getString(obj: std.json.Value, field: []const u8) ?[]const u8 {
    const v = obj.object.get(field) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── tool: shell ───────────────────────────────────────────────────────────────

fn toolShell(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"command":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in shell args" };
    };
    defer parsed.deinit();

    const cmd = getString(parsed.value, "command") orelse "echo \"no command provided\"";

    if (!ctx.policy.allowShellCommand(cmd)) {
        return ToolResult{ .success = false, .output = "command blocked by security policy" };
    }

    // Emit audit log entry before executing.
    ctx.policy.auditLog("shell", cmd) catch {};

    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "shell exec failed: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    const output = try ctx.allocator.dupe(u8, if (result.stdout.len > 0) result.stdout else result.stderr);
    return ToolResult{ .success = result.term == .Exited and result.term.Exited == 0, .output = output };
}

// ── tool: file_read ───────────────────────────────────────────────────────────

fn toolFileRead(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"path":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in file_read args" };
    };
    defer parsed.deinit();

    const path = getString(parsed.value, "path") orelse {
        return ToolResult{ .success = false, .output = "file_read: missing 'path' argument" };
    };

    // Security: reject paths that escape the workspace.
    if (!ctx.policy.allowPath(path)) {
        return ToolResult{ .success = false, .output = "file_read: path outside workspace is not allowed" };
    }

    ctx.policy.auditLog("file_read", path) catch {};

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_read: cannot open '{s}': {}", .{ path, err });
        return ToolResult{ .success = false, .output = msg };
    };
    defer file.close();

    const raw_content = file.readToEndAlloc(ctx.allocator, 4 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_read: read error: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };
    defer ctx.allocator.free(raw_content);

    // T2-5: Cap output to MAX_TOOL_OUTPUT_CHARS to protect context window.
    const content = try capOutput(ctx.allocator, raw_content);
    return ToolResult{ .success = true, .output = content };
}

// ── tool: file_write ──────────────────────────────────────────────────────────

fn toolFileWrite(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"path":"...","content":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in file_write args" };
    };
    defer parsed.deinit();

    const path = getString(parsed.value, "path") orelse {
        return ToolResult{ .success = false, .output = "file_write: missing 'path' argument" };
    };
    const content = getString(parsed.value, "content") orelse "";

    if (!ctx.policy.allowPath(path)) {
        return ToolResult{ .success = false, .output = "file_write: path outside workspace is not allowed" };
    }

    ctx.policy.auditLog("file_write", path) catch {};

    // Ensure parent directory exists.
    const dir_path = std.fs.path.dirname(path);
    if (dir_path) |d| {
        std.fs.cwd().makePath(d) catch {};
    }

    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_write: cannot create '{s}': {}", .{ path, err });
        return ToolResult{ .success = false, .output = msg };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_write: write error: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };

    const msg = try std.fmt.allocPrint(ctx.allocator, "wrote {d} bytes to {s}", .{ content.len, path });
    return ToolResult{ .success = true, .output = msg };
}

// ── tool: memory_store ────────────────────────────────────────────────────────

fn toolMemoryStore(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"key":"...","content":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in memory_store args" };
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse "default";
    const content = getString(parsed.value, "content") orelse "";

    try ctx.memory.store(key, content);
    ctx.policy.auditLog("memory_store", key) catch {};
    return ToolResult{ .success = true, .output = "stored" };
}

// ── tool: memory_recall ───────────────────────────────────────────────────────

fn toolMemoryRecall(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"key":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in memory_recall args" };
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse "default";

    ctx.policy.auditLog("memory_recall", key) catch {};

    const content = ctx.memory.recall(key) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "memory_recall error: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };

    return ToolResult{ .success = true, .output = content };
}

// ── tool: memory_forget ───────────────────────────────────────────────────────

fn toolMemoryForget(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"key":"..."}
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in memory_forget args" };
    };
    defer parsed.deinit();

    const key = getString(parsed.value, "key") orelse "default";

    ctx.policy.auditLog("memory_forget", key) catch {};

    ctx.memory.forget(key) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "memory_forget error: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };

    const msg = try std.fmt.allocPrint(ctx.allocator, "forgot '{s}'", .{key});
    return ToolResult{ .success = true, .output = msg };
}

// ── tool: http_request ────────────────────────────────────────────────────────

fn toolHttpRequest(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"url":"...","method":"GET|POST","body":"...","headers":{}}
    // Only GET and POST are supported for now.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in http_request args" };
    };
    defer parsed.deinit();

    const url_str = getString(parsed.value, "url") orelse {
        return ToolResult{ .success = false, .output = "http_request: missing 'url' argument" };
    };
    const method_str = getString(parsed.value, "method") orelse "GET";
    const body_str = getString(parsed.value, "body") orelse "";

    ctx.policy.auditLog("http_request", url_str) catch {};

    const uri = std.Uri.parse(url_str) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "http_request: invalid URL '{s}'", .{url_str});
        return ToolResult{ .success = false, .output = msg };
    };

    const method: std.http.Method = if (std.mem.eql(u8, method_str, "POST"))
        .POST
    else
        .GET;

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    var response_buf = std.ArrayList(u8).init(ctx.allocator);
    errdefer response_buf.deinit();

    const payload: ?[]const u8 = if (body_str.len > 0) body_str else null;

    const result = client.fetch(.{
        .method = method,
        .location = .{ .uri = uri },
        .payload = payload,
        .response_storage = .{ .dynamic = &response_buf },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "http_request failed: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };

    const success = @intFromEnum(result.status) < 400;
    const output = try response_buf.toOwnedSlice();

    if (!success) {
        const msg = try std.fmt.allocPrint(
            ctx.allocator,
            "HTTP {d}: {s}",
            .{ @intFromEnum(result.status), output },
        );
        ctx.allocator.free(output);
        return ToolResult{ .success = false, .output = msg };
    }

    return ToolResult{ .success = true, .output = output };
}

// ── T1-2: Tool output size cap ────────────────────────────────────────────────
// Maximum bytes returned by any single tool. Prevents a large file_read or
// verbose shell command from consuming the entire model context window.
pub const MAX_TOOL_OUTPUT_CHARS: usize = 8_000;

/// Truncate output to MAX_TOOL_OUTPUT_CHARS, appending a marker if truncated.
/// Returns an owned slice; caller must free.
fn capOutput(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len <= MAX_TOOL_OUTPUT_CHARS) return allocator.dupe(u8, raw);
    const truncated = raw[0..MAX_TOOL_OUTPUT_CHARS];
    return std.fmt.allocPrint(
        allocator,
        "{s}\n[... output truncated at {d} chars ...]",
        .{ truncated, MAX_TOOL_OUTPUT_CHARS },
    );
}

// ── tool: git_operations ──────────────────────────────────────────────────────

fn toolGitOperations(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"op":"clone|status|add|commit|push|log|diff","path":"...","args":"..."}
    //   op    – the git sub-command (allowlisted)
    //   path  – working directory for the git command (must be in workspace)
    //   args  – extra arguments appended after the sub-command (space-separated,
    //           each argument is passed as a separate argv element — NO shell
    //           interpolation, so metacharacters are safe)
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in git_operations args" };
    };
    defer parsed.deinit();

    const op    = getString(parsed.value, "op")   orelse "status";
    const path  = getString(parsed.value, "path") orelse ".";
    const extra = getString(parsed.value, "args") orelse "";

    // Validate allowed operations.
    const allowed_ops = [_][]const u8{
        "status", "log", "diff", "add", "commit", "push", "pull",
        "clone", "init", "branch", "checkout", "fetch", "stash",
    };
    var op_ok = false;
    for (allowed_ops) |allowed| {
        if (std.mem.eql(u8, op, allowed)) { op_ok = true; break; }
    }
    if (!op_ok) {
        return ToolResult{ .success = false, .output = "git_operations: unsupported operation" };
    }

    // Validate path.
    if (!ctx.policy.allowPath(path)) {
        return ToolResult{ .success = false, .output = "git_operations: path outside workspace" };
    }

    ctx.policy.auditLog("git_operations", op) catch {};

    // T1-3: Build argv explicitly — no shell, no string interpolation.
    // Split `extra` on spaces into individual arguments so shell metacharacters
    // in any argument are passed literally to git, not interpreted by a shell.
    var argv = std.ArrayList([]const u8).init(ctx.allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(path);
    try argv.append(op);

    if (extra.len > 0) {
        var word_it = std.mem.splitScalar(u8, extra, ' ');
        while (word_it.next()) |word| {
            const w = std.mem.trim(u8, word, " \t");
            if (w.len > 0) try argv.append(w);
        }
    }

    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv      = argv.items,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "git exec failed: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    const output = try capOutput(ctx.allocator, raw);
    return ToolResult{
        .success = result.term == .Exited and result.term.Exited == 0,
        .output  = output,
    };
}

// ── registry ──────────────────────────────────────────────────────────────────

pub fn buildCoreTools(
    allocator: std.mem.Allocator,
    _: *security_mod.SecurityPolicy,
    _: *memory_mod.MemoryBackend,
) ![]Tool {
    var list = std.ArrayList(Tool).init(allocator);
    errdefer list.deinit();

    try list.append(Tool{ .name = "shell",            .executeFn = toolShell });
    try list.append(Tool{ .name = "file_read",        .executeFn = toolFileRead });
    try list.append(Tool{ .name = "file_write",       .executeFn = toolFileWrite });
    try list.append(Tool{ .name = "memory_store",     .executeFn = toolMemoryStore });
    try list.append(Tool{ .name = "memory_recall",    .executeFn = toolMemoryRecall });
    try list.append(Tool{ .name = "memory_forget",    .executeFn = toolMemoryForget });
    try list.append(Tool{ .name = "http_request",     .executeFn = toolHttpRequest });
    try list.append(Tool{ .name = "git_operations",   .executeFn = toolGitOperations });

    return list.toOwnedSlice();
}

pub fn freeTools(allocator: std.mem.Allocator, tools: []Tool) void {
    allocator.free(tools);
}

// ── MCP proxy tools ───────────────────────────────────────────────────────────
//
// Each MCP server tool is represented as a BareClaw Tool with an McpProxyMeta
// stored in user_data. The single proxy executeFn reads the metadata to
// determine which MCP server to call and which tool name to invoke.

/// Per-tool metadata for MCP proxy tools.
pub const McpProxyMeta = struct {
    /// The argv used to spawn the MCP server subprocess.
    server_argv: []const []const u8, // slice of owned strings
    /// The tool name as published by the MCP server (may differ from Tool.name).
    mcp_tool_name: []const u8, // owned
    /// Human-readable description from the MCP server's tools/list response.
    description: []const u8, // owned

    pub fn deinit(self: *McpProxyMeta, allocator: std.mem.Allocator) void {
        for (self.server_argv) |arg| allocator.free(arg);
        allocator.free(self.server_argv);
        allocator.free(self.mcp_tool_name);
        allocator.free(self.description);
        self.* = undefined;
    }
};

/// Single executeFn for all MCP proxy tools.
/// Reads user_data as *McpProxyMeta to know which server and tool to call.
fn toolMcpProxy(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    const pool = ctx.mcp_pool orelse {
        return ToolResult{ .success = false, .output = "mcp: no session pool in context" };
    };
    // user_data is set by buildMcpTools to point at the McpProxyMeta for this tool.
    // The caller (agent.zig) passes &ctx with the correct tool's user_data already wired in.
    // However, executeFn doesn't receive the Tool struct — we rely on the per-tool
    // context passed via a wrapper. Since Zig has no closures, we use a small trampoline:
    // the tool's name IS the lookup key — but the function doesn't receive its own name.
    //
    // Resolution: We MUST have the metadata available. The contract is that callers
    // wishing to invoke MCP tools must set ctx.mcp_pool AND call via the tool's own
    // executeFn which has user_data set. We embed a thread-local pointer to current meta.
    //
    // Simpler: we accept that ctx needs one more field for MCP tool dispatch.
    // Add mcp_current_meta to ToolContext temporarily, set by dispatchAllToolCalls.
    const meta: *McpProxyMeta = @ptrCast(@alignCast(ctx.mcp_current_meta orelse {
        return ToolResult{ .success = false, .output = "mcp: missing tool metadata in context" };
    }));

    ctx.policy.auditLog("mcp_tool", meta.mcp_tool_name) catch {};

    const session = pool.getOrStart(meta.server_argv) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "mcp: failed to start server: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };

    const result = session.callTool(meta.mcp_tool_name, args_json) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "mcp: call failed: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };

    return ToolResult{ .success = true, .output = result };
}

// T1-5: MCP startup error reporting ──────────────────────────────────────────
//
// Previously, MCP server startup failures were silently logged at warn level
// and skipped. The agent would proceed with zero MCP tools and the user had
// no way to know. Now we collect failures and return them alongside the tools
// so callers can surface them to the user before starting the agent loop.

pub const McpStartupError = struct {
    server_name: []const u8, // owned
    message:     []const u8, // owned

    pub fn deinit(self: *McpStartupError, allocator: std.mem.Allocator) void {
        allocator.free(self.server_name);
        allocator.free(self.message);
        self.* = undefined;
    }
};

/// Build Tool entries for all tools discovered from a set of MCP servers.
/// `server_defs` comes from config_mod.parseMcpServers().
/// The returned tools share a McpSessionPool (also returned via `pool_out`).
/// `errors_out` receives a slice of startup errors (one per failed server).
/// Caller is responsible for calling freeMcpTools(), pool.deinit(), and
/// freeing each McpStartupError + the errors_out slice.
pub fn buildMcpTools(
    allocator: std.mem.Allocator,
    server_defs: []const @import("config.zig").McpServerDef,
    pool_out: *mcp_mod.McpSessionPool,
    errors_out: *[]McpStartupError,
) ![]Tool {
    pool_out.* = mcp_mod.McpSessionPool.init(allocator);

    var list   = std.ArrayList(Tool).init(allocator);
    var errs   = std.ArrayList(McpStartupError).init(allocator);
    errdefer list.deinit();
    errdefer {
        for (errs.items) |*e| e.deinit(allocator);
        errs.deinit();
    }

    for (server_defs) |def| {
        // Start a temporary session to discover the tools list.
        // We immediately deinit it — the pool will re-spawn on first actual call.
        var probe = mcp_mod.McpSession.startProbe(allocator, def.argv) catch |err| {
            // T1-5: Collect the error instead of silently skipping.
            const msg = std.fmt.allocPrint(allocator, "{}", .{err}) catch "unknown error";
            try errs.append(McpStartupError{
                .server_name = try allocator.dupe(u8, def.name),
                .message     = msg,
            });
            continue;
        };
        const discovered = probe.listTools() catch &[_]mcp_mod.McpTool{};
        probe.deinit();

        for (discovered) |mcp_tool| {
            defer {} // mcp_tool strings are owned by discovered; we dupe below

            // Build tool name: "servername__toolname" (double underscore).
            const tool_name = try std.fmt.allocPrint(
                allocator,
                "{s}__{s}",
                .{ def.name, mcp_tool.name },
            );
            errdefer allocator.free(tool_name);

            // Build argv copy for the proxy meta.
            var argv_copy = try allocator.alloc([]const u8, def.argv.len);
            for (def.argv, 0..) |arg, i| argv_copy[i] = try allocator.dupe(u8, arg);

            const desc_copy = try allocator.dupe(u8, mcp_tool.description);
            errdefer allocator.free(desc_copy);

            const meta = try allocator.create(McpProxyMeta);
            meta.* = McpProxyMeta{
                .server_argv   = argv_copy,
                .mcp_tool_name = try allocator.dupe(u8, mcp_tool.name),
                .description   = desc_copy,
            };

            try list.append(Tool{
                .name        = tool_name,
                .description = meta.description, // points into meta — freed via freeMcpTools
                .executeFn   = toolMcpProxy,
                .user_data   = @ptrCast(meta),
            });
        }

        // Free discovered tools (we've duped what we need).
        for (@constCast(discovered)) |*t| t.deinit(allocator);
        allocator.free(discovered);
    }

    errors_out.* = try errs.toOwnedSlice();
    return list.toOwnedSlice();
}

/// Free MCP tools built by buildMcpTools().
pub fn freeMcpTools(allocator: std.mem.Allocator, tools: []Tool) void {
    for (tools) |tool| {
        if (tool.user_data) |ud| {
            const meta: *McpProxyMeta = @ptrCast(@alignCast(ud));
            meta.deinit(allocator);
            allocator.destroy(meta);
        }
        allocator.free(tool.name);
    }
    allocator.free(tools);
}
