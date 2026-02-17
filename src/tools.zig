const std = @import("std");
const security_mod = @import("security.zig");
const memory_mod = @import("memory.zig");

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
};

pub const Tool = struct {
    name: []const u8,
    executeFn: *const fn (ctx: *ToolContext, args_json: []const u8) anyerror!ToolResult,
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    policy: *security_mod.SecurityPolicy,
    memory: *memory_mod.MemoryBackend,
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

    const content = file.readToEndAlloc(ctx.allocator, 4 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "file_read: read error: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };

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

// ── tool: git_operations ──────────────────────────────────────────────────────

fn toolGitOperations(ctx: *ToolContext, args_json: []const u8) !ToolResult {
    // Expected: {"op":"clone|status|add|commit|push|log|diff","path":"...","args":"..."}
    //   op    – the git sub-command
    //   path  – working directory for the git command (must be in workspace)
    //   args  – extra arguments appended after the sub-command
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return ToolResult{ .success = false, .output = "invalid JSON in git_operations args" };
    };
    defer parsed.deinit();

    const op   = getString(parsed.value, "op")   orelse "status";
    const path = getString(parsed.value, "path")  orelse ".";
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

    // Build the shell command: cd <path> && git <op> <args>
    const cmd = try std.fmt.allocPrint(
        ctx.allocator,
        "cd {s} && git {s} {s}",
        .{ path, op, extra },
    );
    defer ctx.allocator.free(cmd);

    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "git exec failed: {}", .{err});
        return ToolResult{ .success = false, .output = msg };
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    const output = try ctx.allocator.dupe(
        u8,
        if (result.stdout.len > 0) result.stdout else result.stderr,
    );
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
