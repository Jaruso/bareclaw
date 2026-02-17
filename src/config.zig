const std = @import("std");

pub const Config = struct {
    workspace_dir: []const u8,
    config_path:   []const u8,

    default_provider:   []const u8,
    default_model:      []const u8,
    memory_backend:     []const u8,
    /// Comma-separated fallback provider names, e.g. "anthropic,openai,ollama"
    fallback_providers: []const u8,

    /// API key for the default provider. Env vars (BARECLAW_API_KEY, ANTHROPIC_API_KEY,
    /// etc.) take precedence at runtime; this is the config-file fallback.
    api_key: []const u8,

    /// Discord bot token (optional)
    discord_token: []const u8,
    /// Discord webhook URL for integration testing (optional)
    discord_webhook: []const u8,
    /// Telegram bot token (optional)
    telegram_token: []const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_dir);
        allocator.free(self.config_path);
        allocator.free(self.default_provider);
        allocator.free(self.default_model);
        allocator.free(self.memory_backend);
        allocator.free(self.fallback_providers);
        allocator.free(self.api_key);
        allocator.free(self.discord_token);
        allocator.free(self.discord_webhook);
        allocator.free(self.telegram_token);
        self.* = undefined;
    }

    pub fn save(self: *const Config) !void {
        var file = try std.fs.cwd().createFile(self.config_path, .{ .truncate = true });
        defer file.close();
        const w = file.writer();
        try w.print(
            "default_provider   = \"{s}\"\n" ++
            "default_model      = \"{s}\"\n" ++
            "memory_backend     = \"{s}\"\n" ++
            "fallback_providers = \"{s}\"\n" ++
            "api_key            = \"{s}\"\n" ++
            "\n" ++
            "# Channel tokens\n" ++
            "discord_token   = \"{s}\"\n" ++
            "discord_webhook = \"{s}\"\n" ++
            "telegram_token  = \"{s}\"\n",
            .{
                self.default_provider, self.default_model,
                self.memory_backend,   self.fallback_providers,
                self.api_key,
                self.discord_token,    self.discord_webhook,  self.telegram_token,
            },
        );
    }

    /// Update a single config key in memory and persist to disk.
    /// Returns an error string (caller frees) on unknown key, null on success.
    pub fn setKey(self: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !?[]u8 {
        const known_keys = [_][]const u8{
            "default_provider", "default_model", "memory_backend",
            "fallback_providers", "api_key", "discord_token", "discord_webhook", "telegram_token",
        };
        var found = false;
        for (known_keys) |k| {
            if (std.mem.eql(u8, key, k)) { found = true; break; }
        }
        if (!found) {
            return try std.fmt.allocPrint(
                allocator,
                "Unknown config key: \"{s}\"\nValid keys: default_provider, default_model, memory_backend, fallback_providers, api_key, discord_token, discord_webhook, telegram_token",
                .{key},
            );
        }

        const duped = try allocator.dupe(u8, value);

        if (std.mem.eql(u8, key, "default_provider")) {
            allocator.free(self.default_provider);
            self.default_provider = duped;
        } else if (std.mem.eql(u8, key, "default_model")) {
            allocator.free(self.default_model);
            self.default_model = duped;
        } else if (std.mem.eql(u8, key, "memory_backend")) {
            allocator.free(self.memory_backend);
            self.memory_backend = duped;
        } else if (std.mem.eql(u8, key, "fallback_providers")) {
            allocator.free(self.fallback_providers);
            self.fallback_providers = duped;
        } else if (std.mem.eql(u8, key, "api_key")) {
            allocator.free(self.api_key);
            self.api_key = duped;
        } else if (std.mem.eql(u8, key, "discord_token")) {
            allocator.free(self.discord_token);
            self.discord_token = duped;
        } else if (std.mem.eql(u8, key, "discord_webhook")) {
            allocator.free(self.discord_webhook);
            self.discord_webhook = duped;
        } else if (std.mem.eql(u8, key, "telegram_token")) {
            allocator.free(self.telegram_token);
            self.telegram_token = duped;
        } else {
            allocator.free(duped);
        }

        try self.save();
        return null; // success
    }
};

pub fn loadOrInit(allocator: std.mem.Allocator) !Config {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const c_allocator = std.heap.c_allocator;
    const workspace_dir_buf = try std.fs.path.join(c_allocator, &.{ home, ".bareclaw", "workspace" });
    defer c_allocator.free(workspace_dir_buf);
    const config_path_buf = try std.fs.path.join(c_allocator, &.{ home, ".bareclaw", "config.toml" });
    defer c_allocator.free(config_path_buf);

    // Ensure workspace directory exists.
    {
        var cwd = std.fs.cwd();
        _ = cwd.makePath(workspace_dir_buf) catch {};
    }

    var cfg = Config{
        .workspace_dir      = try allocator.dupe(u8, workspace_dir_buf),
        .config_path        = try allocator.dupe(u8, config_path_buf),
        .default_provider   = try allocator.dupe(u8, "openai-compatible"),
        .default_model      = try allocator.dupe(u8, "gpt-4.1-mini"),
        .memory_backend     = try allocator.dupe(u8, "markdown"),
        .fallback_providers = try allocator.dupe(u8, ""),
        .api_key            = try allocator.dupe(u8, ""),
        .discord_token      = try allocator.dupe(u8, ""),
        .discord_webhook    = try allocator.dupe(u8, ""),
        .telegram_token     = try allocator.dupe(u8, ""),
    };

    // Best-effort: parse existing config.toml for a few keys.
    var file = std.fs.cwd().openFile(config_path_buf, .{}) catch |err| switch (err) {
        error.FileNotFound => return cfg,
        else => return cfg,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 16 * 1024);
    defer allocator.free(contents);

    parseSimpleToml(&cfg, contents, allocator) catch {};
    return cfg;
}

fn parseSimpleToml(cfg: *Config, contents: []u8, allocator: std.mem.Allocator) !void {
    var it = std.mem.tokenizeScalar(u8, contents, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "default_provider")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.default_provider);
                cfg.default_provider = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "default_model")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.default_model);
                cfg.default_model = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "memory_backend")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.memory_backend);
                cfg.memory_backend = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "fallback_providers")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.fallback_providers);
                cfg.fallback_providers = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "api_key")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.api_key);
                cfg.api_key = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "discord_webhook")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.discord_webhook);
                cfg.discord_webhook = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "discord_token")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.discord_token);
                cfg.discord_token = try allocator.dupe(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "telegram_token")) {
            if (parseValue(line)) |val| {
                allocator.free(cfg.telegram_token);
                cfg.telegram_token = try allocator.dupe(u8, val);
            }
        }
    }
}

fn parseValue(line: []const u8) ?[]const u8 {
    const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    var rest = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
    if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') {
        rest = rest[1 .. rest.len - 1];
    }
    return rest;
}

pub fn quickOnboard(cfg: *Config, allocator: std.mem.Allocator, writer: anytype) !void {
    _ = allocator;
    try writer.print("BareClaw quick onboarding...\n", .{});
    try writer.print("Using workspace at {s}\n", .{cfg.workspace_dir});
    try writer.print("Default provider: {s}\n", .{cfg.default_provider});
    try writer.print("Default model:    {s}\n", .{cfg.default_model});
    try writer.print("Memory backend:   {s}\n", .{cfg.memory_backend});
}

