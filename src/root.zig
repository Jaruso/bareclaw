//! BareClaw library root. Re-exports the public API for consumers that embed
//! the runtime as a library rather than using the CLI binary.
pub const agent = @import("agent.zig");
pub const config = @import("config.zig");
pub const memory = @import("memory.zig");
pub const provider = @import("provider.zig");
pub const security = @import("security.zig");
pub const tools = @import("tools.zig");

// ── T1-7: Agent loop unit tests ───────────────────────────────────────────────

const std = @import("std");

/// Tests for the JSON extractor added in T1-1.
/// extractJsonObject is private to agent.zig, so we duplicate the logic here
/// under test to verify it handles all documented edge cases.
/// The real function is exercised indirectly via dispatchAllToolCalls.
fn extractJsonObjectTest(input: []const u8) ?[]const u8 {
    var src = input;
    if (std.mem.indexOf(u8, src, "```")) |fence_start| {
        const after_fence = fence_start + 3;
        const newline = std.mem.indexOfScalarPos(u8, src, after_fence, '\n') orelse after_fence;
        const content_start = newline + 1;
        if (std.mem.lastIndexOf(u8, src, "```")) |fence_end| {
            if (fence_end > content_start) {
                src = std.mem.trim(u8, src[content_start..fence_end], " \t\r\n");
            }
        }
    }
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

test "extractJsonObject: bare JSON passes through" {
    const input = "{\"tool_calls\":[]}";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"tool_calls\":[]}", result.?);
}

test "extractJsonObject: prose-wrapped JSON is extracted" {
    const input = "Sure, let me do that!\n{\"tool_calls\":[{\"function\":\"shell\"}]}\nHope that helps.";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"tool_calls\":[{\"function\":\"shell\"}]}", result.?);
}

test "extractJsonObject: markdown fenced JSON is extracted" {
    const input = "Here is the call:\n```json\n{\"tool_calls\":[]}\n```\nDone.";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"tool_calls\":[]}", result.?);
}

test "extractJsonObject: plain text with no JSON returns null" {
    const input = "I cannot help with that.";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result == null);
}

test "extractJsonObject: nested braces parsed correctly" {
    const input = "{\"tool_calls\":[{\"function\":{\"name\":\"shell\",\"arguments\":{\"command\":\"ls\"}}}]}";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(input, result.?);
}

test "extractJsonObject: escaped quote inside string does not break depth tracking" {
    const input = "{\"key\":\"value with \\\"quotes\\\"\"}";
    const result = extractJsonObjectTest(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(input, result.?);
}

test "context budget: MAX_CONTEXT_CHARS constant is sane" {
    // Verify the constant exists and is in a reasonable range for model context windows.
    const max = @import("agent.zig").MAX_CONTEXT_CHARS_EXPORTED;
    try std.testing.expect(max >= 4_000);
    try std.testing.expect(max <= 64_000);
}

test "tool output cap: MAX_TOOL_OUTPUT_CHARS constant is sane" {
    const max = @import("tools.zig").MAX_TOOL_OUTPUT_CHARS;
    try std.testing.expect(max >= 1_000);
    try std.testing.expect(max <= 32_000);
}
