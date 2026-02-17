/// Cron scheduler for BareClaw.
///
/// Tasks are stored as one-per-line TSV in  ~/.bareclaw/cron.tsv:
///   id TAB schedule TAB command TAB enabled TAB last_run_ts NEWLINE
///
/// Supported subcommands (from main.zig / args):
///   cron add <schedule> <command>   – add a new task
///   cron list                       – print all tasks
///   cron remove <id>                – delete a task by id
///   cron pause  <id>                – set enabled=false
///   cron resume <id>                – set enabled=true
///   cron run                        – execute all due/enabled tasks right now

const std = @import("std");

// ── data model ──────────────────────────────────────────────────────────────

pub const CronTask = struct {
    id:         []const u8,  // allocated
    schedule:   []const u8,  // allocated – e.g. "@daily", "0 * * * *"
    command:    []const u8,  // allocated – shell command string
    enabled:    bool,
    last_run:   i64,         // unix timestamp, 0 = never

    pub fn deinit(self: *CronTask, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.schedule);
        allocator.free(self.command);
    }
};

// ── helpers ──────────────────────────────────────────────────────────────────

fn cronFilePath(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".bareclaw", "cron.tsv" });
}

/// Ensure ~/.bareclaw exists.
fn ensureDir(allocator: std.mem.Allocator) !void {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const dir = try std.fs.path.join(allocator, &.{ home, ".bareclaw" });
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
}

/// Load all tasks from disk. Caller owns the returned slice and each CronTask.
fn loadTasks(allocator: std.mem.Allocator) ![]CronTask {
    const path = try cronFilePath(allocator);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(CronTask, 0),
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    var tasks = std.ArrayList(CronTask).init(allocator);
    errdefer {
        for (tasks.items) |*t| t.deinit(allocator);
        tasks.deinit();
    }

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, trimmed, '\t');
        const id       = fields.next() orelse continue;
        const schedule = fields.next() orelse continue;
        const command  = fields.next() orelse continue;
        const en_str   = fields.next() orelse "1";
        const lr_str   = fields.next() orelse "0";

        const task = CronTask{
            .id       = try allocator.dupe(u8, id),
            .schedule = try allocator.dupe(u8, schedule),
            .command  = try allocator.dupe(u8, command),
            .enabled  = !std.mem.eql(u8, en_str, "0"),
            .last_run = std.fmt.parseInt(i64, lr_str, 10) catch 0,
        };
        try tasks.append(task);
    }

    return tasks.toOwnedSlice();
}

/// Public wrapper so other modules (e.g. main.zig status/doctor) can read tasks.
pub fn loadTasksPublic(allocator: std.mem.Allocator) ![]CronTask {
    return loadTasks(allocator);
}

/// Write tasks slice back to disk (full rewrite).
fn saveTasks(allocator: std.mem.Allocator, tasks: []const CronTask) !void {
    try ensureDir(allocator);
    const path = try cronFilePath(allocator);
    defer allocator.free(path);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const w = file.writer();
    for (tasks) |t| {
        try w.print("{s}\t{s}\t{s}\t{d}\t{d}\n", .{
            t.id,
            t.schedule,
            t.command,
            @intFromBool(t.enabled),
            t.last_run,
        });
    }
}

/// Generate a short unique id like "t1", "t2", …
fn nextId(allocator: std.mem.Allocator, tasks: []const CronTask) ![]u8 {
    var max: usize = 0;
    for (tasks) |t| {
        if (t.id.len > 1 and t.id[0] == 't') {
            const n = std.fmt.parseInt(usize, t.id[1..], 10) catch continue;
            if (n > max) max = n;
        }
    }
    return std.fmt.allocPrint(allocator, "t{d}", .{max + 1});
}

// ── public interface ─────────────────────────────────────────────────────────

/// Entry point called from main.zig with the remaining args after "cron".
/// args[0] is the subcommand (add / list / remove / pause / resume / run).
pub fn dispatchCron(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stdout = std.io.getStdOut().writer();

    const sub = if (args.len > 0) args[0] else "list";

    if (std.mem.eql(u8, sub, "list")) {
        try cmdList(allocator, stdout);
    } else if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 3) {
            try stdout.print("Usage: cron add <schedule> <command>\n", .{});
            return;
        }
        try cmdAdd(allocator, args[1], args[2], stdout);
    } else if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "rm")) {
        if (args.len < 2) {
            try stdout.print("Usage: cron remove <id>\n", .{});
            return;
        }
        try cmdRemove(allocator, args[1], stdout);
    } else if (std.mem.eql(u8, sub, "pause")) {
        if (args.len < 2) {
            try stdout.print("Usage: cron pause <id>\n", .{});
            return;
        }
        try cmdSetEnabled(allocator, args[1], false, stdout);
    } else if (std.mem.eql(u8, sub, "resume")) {
        if (args.len < 2) {
            try stdout.print("Usage: cron resume <id>\n", .{});
            return;
        }
        try cmdSetEnabled(allocator, args[1], true, stdout);
    } else if (std.mem.eql(u8, sub, "run")) {
        try cmdRun(allocator, stdout);
    } else {
        try stdout.print("Unknown cron subcommand: {s}\n", .{sub});
        try stdout.print("Subcommands: list | add | remove | pause | resume | run\n", .{});
    }
}

/// Legacy: no-args cron just runs all due tasks.
pub fn runCronOnce(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    try cmdRun(allocator, stdout);
}

// ── subcommands ──────────────────────────────────────────────────────────────

fn cmdList(allocator: std.mem.Allocator, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(tasks);
    }

    if (tasks.len == 0) {
        try stdout.print("No cron tasks. Add one with: cron add <schedule> <command>\n", .{});
        return;
    }

    try stdout.print("{s:<8} {s:<12} {s:<6} {s}\n", .{ "ID", "SCHEDULE", "ON?", "COMMAND" });
    try stdout.print("{s}\n", .{"-" ** 60});
    for (tasks) |t| {
        const on = if (t.enabled) "yes" else "no";
        try stdout.print("{s:<8} {s:<12} {s:<6} {s}\n", .{ t.id, t.schedule, on, t.command });
    }
}

fn cmdAdd(allocator: std.mem.Allocator, schedule: []const u8, command: []const u8, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(tasks);
    }

    const id = try nextId(allocator, tasks);
    defer allocator.free(id);

    // Build a new list with the extra task appended.
    var new_tasks = try std.ArrayList(CronTask).initCapacity(allocator, tasks.len + 1);
    defer new_tasks.deinit();
    for (tasks) |t| try new_tasks.append(t);
    try new_tasks.append(CronTask{
        .id       = id,
        .schedule = schedule,
        .command  = command,
        .enabled  = true,
        .last_run = 0,
    });

    try saveTasks(allocator, new_tasks.items);
    try stdout.print("Added cron task {s}: [{s}] {s}\n", .{ id, schedule, command });
}

fn cmdRemove(allocator: std.mem.Allocator, id: []const u8, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| @constCast(t).deinit(allocator);
        allocator.free(tasks);
    }

    var kept = std.ArrayList(CronTask).init(allocator);
    defer kept.deinit();
    var found = false;
    for (tasks) |t| {
        if (std.mem.eql(u8, t.id, id)) { found = true; continue; }
        try kept.append(t);
    }

    if (!found) {
        try stdout.print("Cron task '{s}' not found.\n", .{id});
        return;
    }

    try saveTasks(allocator, kept.items);
    try stdout.print("Removed cron task {s}.\n", .{id});
}

fn cmdSetEnabled(allocator: std.mem.Allocator, id: []const u8, enabled: bool, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| t.deinit(allocator);
        allocator.free(tasks);
    }

    var found = false;
    for (tasks) |*t| {
        if (std.mem.eql(u8, t.id, id)) {
            t.enabled = enabled;
            found = true;
        }
    }

    if (!found) {
        try stdout.print("Cron task '{s}' not found.\n", .{id});
        return;
    }

    try saveTasks(allocator, tasks);
    const verb = if (enabled) "resumed" else "paused";
    try stdout.print("Cron task {s} {s}.\n", .{ id, verb });
}

/// Run all enabled tasks immediately (ignores schedule for now, runs all).
fn cmdRun(allocator: std.mem.Allocator, stdout: anytype) !void {
    const tasks = try loadTasks(allocator);
    defer {
        for (tasks) |*t| t.deinit(allocator);
        allocator.free(tasks);
    }

    if (tasks.len == 0) {
        try stdout.print("No cron tasks to run.\n", .{});
        return;
    }

    const now = std.time.timestamp();
    var ran: usize = 0;

    for (tasks) |*t| {
        if (!t.enabled) continue;

        try stdout.print("[cron] running {s}: {s}\n", .{ t.id, t.command });

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", t.command },
        }) catch |err| {
            try stdout.print("[cron] {s} error: {}\n", .{ t.id, err });
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const out = if (result.stdout.len > 0) result.stdout else result.stderr;
        if (out.len > 0) try stdout.print("{s}", .{out});

        t.last_run = now;
        ran += 1;
    }

    try saveTasks(allocator, tasks);
    try stdout.print("[cron] ran {d} task(s).\n", .{ran});
}
