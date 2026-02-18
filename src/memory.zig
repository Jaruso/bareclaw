const std = @import("std");
const config_mod = @import("config.zig");

pub const BackendKind = enum {
    markdown,
    sqlite,
};

pub const MemoryBackend = struct {
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    kind: BackendKind,

    pub fn deinit(self: *MemoryBackend) void {
        self.allocator.free(self.workspace_dir);
    }

    pub fn store(self: *MemoryBackend, key: []const u8, content: []const u8) !void {
        switch (self.kind) {
            .markdown => try storeMarkdown(self, key, content),
            .sqlite => try storeSqliteLike(self, key, content),
        }
    }

    /// Recall memory for a key. Reads the stored markdown file if it exists.
    /// Falls back to scanning all memory files for a substring match on key.
    pub fn recall(self: *MemoryBackend, key: []const u8) ![]u8 {
        var path_buf = std.ArrayList(u8).init(self.allocator);
        defer path_buf.deinit();

        try path_buf.appendSlice(self.workspace_dir);
        try path_buf.append(std.fs.path.sep);
        try path_buf.appendSlice("memory");
        try path_buf.append(std.fs.path.sep);
        try path_buf.appendSlice(key);
        try path_buf.appendSlice(".md");

        // Try exact key match first.
        const file = std.fs.cwd().openFile(path_buf.items, .{}) catch null;
        if (file) |f| {
            defer f.close();
            const content = try f.readToEndAlloc(self.allocator, 1024 * 1024);
            return content;
        }

        // Fall back: scan memory dir for any file containing the key as a substring.
        var mem_dir_buf = std.ArrayList(u8).init(self.allocator);
        defer mem_dir_buf.deinit();
        try mem_dir_buf.appendSlice(self.workspace_dir);
        try mem_dir_buf.append(std.fs.path.sep);
        try mem_dir_buf.appendSlice("memory");

        var dir = std.fs.cwd().openDir(mem_dir_buf.items, .{ .iterate = true }) catch {
            return self.allocator.dupe(u8, "(no memory yet)");
        };
        defer dir.close();

        var results = std.ArrayList(u8).init(self.allocator);
        errdefer results.deinit();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.name, key) == null) continue;

            const entry_file = dir.openFile(entry.name, .{}) catch continue;
            defer entry_file.close();
            const content = entry_file.readToEndAlloc(self.allocator, 1024 * 1024) catch continue;
            defer self.allocator.free(content);

            if (results.items.len > 0) try results.appendSlice("\n---\n");
            try results.appendSlice(entry.name);
            try results.appendSlice(":\n");
            try results.appendSlice(content);
        }

        if (results.items.len == 0) {
            return self.allocator.dupe(u8, "(no matching memory found)");
        }
        return results.toOwnedSlice();
    }

    /// Delete the memory file for the given key.
    /// Returns error.FileNotFound (wrapped) if no such key exists.
    pub fn forget(self: *MemoryBackend, key: []const u8) !void {
        var path_buf = std.ArrayList(u8).init(self.allocator);
        defer path_buf.deinit();

        try path_buf.appendSlice(self.workspace_dir);
        try path_buf.append(std.fs.path.sep);
        try path_buf.appendSlice("memory");
        try path_buf.append(std.fs.path.sep);
        try path_buf.appendSlice(key);
        try path_buf.appendSlice(".md");

        std.fs.cwd().deleteFile(path_buf.items) catch |err| switch (err) {
            error.FileNotFound => return, // already gone – treat as success
            else => return err,
        };
    }
};

fn storeMarkdown(self: *MemoryBackend, key: []const u8, content: []const u8) !void {
    var path_buf = std.ArrayList(u8).init(self.allocator);
    defer path_buf.deinit();

    try path_buf.appendSlice(self.workspace_dir);
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice("memory");
    try path_buf.append(std.fs.path.sep);
    try path_buf.appendSlice(key);
    try path_buf.appendSlice(".md");

    var cwd = std.fs.cwd();
    // Ensure the full parent directory chain exists.
    // This handles nested keys like "cron/t1/1700000000" which require
    // memory/cron/t1/ to exist before the file can be created.
    if (std.fs.path.dirname(path_buf.items)) |parent| {
        cwd.makePath(parent) catch {};
    }

    var file = try cwd.createFile(path_buf.items, .{ .truncate = true, .read = false });
    defer file.close();

    try file.writeAll(content);
    try file.writeAll("\n");
}

fn storeSqliteLike(self: *MemoryBackend, key: []const u8, content: []const u8) !void {
    // Placeholder: in a future phase this will write to a real SQLite
    // database file (brain.db) using C FFI bindings. For now, we mirror
    // the markdown backend so the interface is exercised.
    try storeMarkdown(self, key, content);
}

pub fn createMemoryBackend(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !MemoryBackend {
    const ws = try allocator.dupe(u8, cfg.workspace_dir);
    const kind: BackendKind = blk: {
        if (std.mem.eql(u8, cfg.memory_backend, "sqlite")) break :blk .sqlite;
        break :blk .markdown;
    };

    return MemoryBackend{
        .allocator = allocator,
        .workspace_dir = ws,
        .kind = kind,
    };
}

