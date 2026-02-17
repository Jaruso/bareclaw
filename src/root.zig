//! BareClaw library root. Re-exports the public API for consumers that embed
//! the runtime as a library rather than using the CLI binary.
pub const agent = @import("agent.zig");
pub const config = @import("config.zig");
pub const memory = @import("memory.zig");
pub const provider = @import("provider.zig");
pub const security = @import("security.zig");
pub const tools = @import("tools.zig");
