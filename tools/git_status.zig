const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "git_status"),
                .description = try allocator.dupe(u8, "Shows git working tree status including modified, staged, and untracked files. Works on the current working directory."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {},
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_status",
            .description = "Show git repository status",
            .risk_level = .safe,
            .required_scopes = &.{.read_files},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = arguments;
    _ = context;
    const start_time = std.time.milliTimestamp();

    // Execute git status with porcelain output for consistent parsing
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain=v1" },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute git command: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check exit code
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                const msg = if (result.stderr.len > 0)
                    try std.fmt.allocPrint(allocator, "git status failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git status failed (not a git repository?)");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git status terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Get last commit info for context
    var last_commit_info: []const u8 = "";
    var last_commit_allocated = false;
    const log_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "log", "-1", "--oneline" },
    }) catch null;
    if (log_result) |lr| {
        defer allocator.free(lr.stderr);
        if (lr.term == .Exited and lr.term.Exited == 0 and lr.stdout.len > 0) {
            const trimmed = std.mem.trim(u8, lr.stdout, " \t\r\n");
            last_commit_info = std.fmt.allocPrint(allocator, "\nLast commit: {s}", .{trimmed}) catch "";
            if (last_commit_info.len > 0) last_commit_allocated = true;
        }
        allocator.free(lr.stdout);
    }
    defer if (last_commit_allocated) allocator.free(last_commit_info);

    // Format output - if empty, show clean message with last commit
    const formatted = if (result.stdout.len == 0)
        try std.fmt.allocPrint(allocator, "Working tree clean - all changes are committed.{s}\n\nNote: Use git_diff(from_commit: \"<started_at_commit>\") to see what was committed for this task.", .{last_commit_info})
    else
        try std.fmt.allocPrint(allocator, "```\n{s}```{s}", .{ result.stdout, last_commit_info });
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
