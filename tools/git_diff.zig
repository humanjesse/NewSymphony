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
                .name = try allocator.dupe(u8, "git_diff"),
                .description = try allocator.dupe(u8, "Shows changes in files. Can show unstaged changes (default), staged changes, or changes between commits. Use from_commit/to_commit for reviewing task-specific changes."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "file_path": {
                    \\      "type": "string",
                    \\      "description": "Optional: specific file path to show diff for"
                    \\    },
                    \\    "staged": {
                    \\      "type": "boolean",
                    \\      "description": "If true, shows staged changes (git diff --cached). Ignored if from_commit is specified."
                    \\    },
                    \\    "from_commit": {
                    \\      "type": "string",
                    \\      "description": "Start commit for range diff (e.g., started_at_commit from task). Shows changes FROM this commit."
                    \\    },
                    \\    "to_commit": {
                    \\      "type": "string",
                    \\      "description": "End commit for range diff. Defaults to HEAD if from_commit is specified but to_commit is not."
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_diff",
            .description = "Show git file changes",
            .risk_level = .safe,
            .required_scopes = &.{.read_files},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context;
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        file_path: ?[]const u8 = null,
        staged: ?bool = null,
        from_commit: ?[]const u8 = null,
        to_commit: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Invalid JSON arguments: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .parse_error, msg, start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Build git diff command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 7);
    defer argv.deinit(allocator);

    // Track allocated range string for cleanup
    var range_str: ?[]const u8 = null;
    defer if (range_str) |r| allocator.free(r);

    try argv.append(allocator, "git");
    try argv.append(allocator, "diff");

    // Commit range diff takes priority over staged diff
    if (args.from_commit) |from| {
        // Build commit range: from..to (or from..HEAD if to not specified)
        const to = args.to_commit orelse "HEAD";
        range_str = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ from, to });
        try argv.append(allocator, range_str.?);
    } else if (args.staged orelse false) {
        // Show staged changes only if not doing commit range diff
        try argv.append(allocator, "--cached");
    }

    // Add file path if provided
    if (args.file_path) |path| {
        try argv.append(allocator, "--");
        try argv.append(allocator, path);
    }

    // Execute git diff
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
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
                    try std.fmt.allocPrint(allocator, "git diff failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git diff failed (not a git repository?)");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git diff terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format output - if empty, show no changes message
    const formatted = if (result.stdout.len == 0)
        try allocator.dupe(u8, "No changes detected")
    else
        try std.fmt.allocPrint(allocator, "```diff\n{s}```", .{result.stdout});
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
