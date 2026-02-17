const std = @import("std");
const config_mod = @import("config.zig");

pub const SecurityPolicy = struct {
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    owns_workspace_dir: bool,

    pub fn initWorkspaceOnly(allocator: std.mem.Allocator, cfg: *const config_mod.Config) SecurityPolicy {
        const duped = allocator.dupe(u8, cfg.workspace_dir) catch cfg.workspace_dir;
        const owns = duped.ptr != cfg.workspace_dir.ptr;
        return SecurityPolicy{
            .allocator = allocator,
            .workspace_dir = duped,
            .owns_workspace_dir = owns,
        };
    }

    pub fn deinit(self: *SecurityPolicy, allocator: std.mem.Allocator) void {
        if (self.owns_workspace_dir) {
            allocator.free(self.workspace_dir);
        }
    }

    /// Return true only if the path is inside the workspace directory.
    /// Absolute paths must be under workspace_dir; relative paths are allowed.
    pub fn allowPath(self: *const SecurityPolicy, path: []const u8) bool {
        // Reject obvious directory traversal.
        if (std.mem.indexOf(u8, path, "..") != null) return false;

        // Forbidden absolute path prefixes.
        const forbidden = [_][]const u8{
            "/etc/", "/etc",
            "/root/", "/root",
            "/usr/", "/proc/",
            "/sys/", "/dev/",
        };
        for (forbidden) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return false;
        }

        // Reject sensitive hidden dirs regardless of position in path.
        const sensitive = [_][]const u8{ "/.ssh", "/.gnupg", "/.aws", "/.bareclaw/secrets" };
        for (sensitive) |suf| {
            if (std.mem.indexOf(u8, path, suf) != null) return false;
        }

        // Absolute paths must be inside the workspace.
        if (std.fs.path.isAbsolute(path)) {
            return std.mem.startsWith(u8, path, self.workspace_dir);
        }

        // Relative paths are permitted (resolve under cwd = workspace).
        return true;
    }

    pub fn allowShellCommand(self: *SecurityPolicy, cmd: []const u8) bool {
        _ = self;
        // Blocklist of destructive or dangerous patterns. This checks the
        // trimmed command start and common bypass forms. Not a sandbox —
        // a full sandbox requires OS-level isolation. These checks catch
        // accidental or naive misuse.
        const trimmed = std.mem.trim(u8, cmd, " \t");

        // Blocked command prefixes and their common absolute-path variants.
        const blocked = [_][]const u8{
            "rm ",      "rm\t",
            "/bin/rm",  "/usr/bin/rm",
            "unlink ",  "unlink\t",
            "rmdir ",   "rmdir\t",
            "shred ",   "shred\t",
            "dd ",      // overwrite/wipe
            "> /",      // redirect-truncate to absolute path
            "mkfs",     // format filesystem
            "fdisk",
            "parted",
            ":(){",     // fork bomb
        };

        for (blocked) |pattern| {
            if (std.mem.startsWith(u8, trimmed, pattern)) return false;
            // Also catch mid-command piped or chained forms.
            if (std.mem.indexOf(u8, trimmed, pattern) != null and
                std.mem.indexOf(u8, trimmed, "echo") == null) return false;
        }

        return true;
    }

    /// Append an entry to the audit log at <workspace>/audit.log.
    /// Format per line:  unix_timestamp TAB tool TAB detail NEWLINE
    /// Errors are silently ignored so they never interrupt the calling tool.
    pub fn auditLog(self: *const SecurityPolicy, tool: []const u8, detail: []const u8) !void {
        var path_buf = std.ArrayList(u8).init(self.allocator);
        defer path_buf.deinit();
        try path_buf.appendSlice(self.workspace_dir);
        try path_buf.append(std.fs.path.sep);
        try path_buf.appendSlice("audit.log");

        std.fs.cwd().makePath(self.workspace_dir) catch {};

        var file = try std.fs.cwd().createFile(path_buf.items, .{
            .truncate = false,
            .read    = false,
        });
        defer file.close();
        try file.seekFromEnd(0);

        const ts = std.time.timestamp();
        const w = file.writer();
        try w.print("{d}\t{s}\t{s}\n", .{ ts, tool, detail });
    }
};

pub const SecretStore = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SecretStore {
        return SecretStore{ .allocator = allocator };
    }

    pub fn saveApiKey(self: *SecretStore, name: []const u8, value: []const u8) !void {
        var path = std.ArrayList(u8).init(self.allocator);
        defer path.deinit();
        try path.writer().print("{s}/.bareclaw/secrets-{s}.txt", .{ try std.process.getEnvVarOwned(self.allocator, "HOME"), name });
        var file = try std.fs.cwd().createFile(path.items, .{ .truncate = true });
        defer file.close();
        try file.writeAll(value);
    }
};

