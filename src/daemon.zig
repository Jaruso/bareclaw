const std = @import("std");
const gateway_mod = @import("gateway.zig");
const cron_mod = @import("cron.zig");

pub fn runDaemon(allocator: std.mem.Allocator, port: u16) !void {
    var stdout = std.io.getStdOut().writer();
    try stdout.print("BareClaw daemon starting (stub)...\n", .{});
    try gateway_mod.runGateway(port);
    try cron_mod.runCronOnce(allocator);
    try stdout.print("BareClaw daemon exiting (stub).\n", .{});
}

