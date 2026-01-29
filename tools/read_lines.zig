// Read Tool - Primary file reading tool with line range support
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Maximum line range per read call
const MAX_LINE_RANGE = 500;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "read"),
                .description = try allocator.dupe(u8, "Read a file. Specify line ranges to read specific sections."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "The relative path to the file from the project root"
                    \\    },
                    \\    "start_line": {
                    \\      "type": "integer",
                    \\      "description": "First line number to read (1-indexed, inclusive)"
                    \\    },
                    \\    "end_line": {
                    \\      "type": "integer",
                    \\      "description": "Last line number to read (1-indexed, inclusive)"
                    \\    }
                    \\  },
                    \\  "required": ["path", "start_line", "end_line"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "read",
            .description = "Read a file with optional line ranges",
            .risk_level = .low, // Low risk - read-only, no expensive side effects
            .required_scopes = &.{.read_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        path: []const u8,
        start_line: usize,
        end_line: usize,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // Validate line numbers
    if (parsed.value.start_line == 0) {
        return ToolResult.err(allocator, .validation_failed, "start_line must be >= 1 (lines are 1-indexed)", start_time);
    }

    if (parsed.value.start_line > parsed.value.end_line) {
        return ToolResult.err(allocator, .validation_failed, "start_line must be <= end_line", start_time);
    }

    // Check line range limit
    const requested_lines = parsed.value.end_line - parsed.value.start_line + 1;
    if (requested_lines > MAX_LINE_RANGE) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Requested {d} lines. Maximum range is {d} lines. Make multiple read calls to read more.",
            .{ requested_lines, MAX_LINE_RANGE },
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Read the file
    const file = std.fs.cwd().openFile(parsed.value.path, .{}) catch {
        const msg = try std.fmt.allocPrint(allocator, "File not found: {s}", .{parsed.value.path});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .not_found, msg, start_time);
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "IO error reading file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(content);

    // Handle empty file - check content directly since splitScalar returns 1 element for ""
    if (content.len == 0) {
        // Still mark file as read so agent can edit it
        try context.state.markFileAsRead(parsed.value.path);

        const msg = try std.fmt.allocPrint(
            allocator,
            "File: {s}\nFile is empty (0 lines)",
            .{parsed.value.path},
        );
        defer allocator.free(msg);
        return ToolResult.ok(allocator, msg, start_time, null);
    }

    // Split content into lines
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    // Handle trailing newline - splitScalar creates empty element after final '\n'
    // Most text files end with '\n', so "hello\n" should be 1 line, not 2
    if (content.len > 0 and content[content.len - 1] == '\n') {
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
            _ = lines.pop();
        }
    }

    const total_lines = lines.items.len;

    // Validate start_line is within bounds
    if (parsed.value.start_line > total_lines) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "start_line {d} out of range (file has {d} line{s})",
            .{ parsed.value.start_line, total_lines, if (total_lines == 1) "" else "s" },
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Clamp end_line to file bounds (be lenient if agent requests beyond file)
    const actual_end_line = @min(parsed.value.end_line, total_lines);

    // Format output with line numbers
    var formatted_output = std.ArrayListUnmanaged(u8){};
    defer formatted_output.deinit(allocator);
    const writer = formatted_output.writer(allocator);

    // Wrap in code fence for proper formatting
    try writer.writeAll("```\n");

    // Write header (show actual range returned, which may be clamped)
    try writer.print("File: {s}\n", .{parsed.value.path});
    try writer.print("Lines: {d}-{d} of {d} total\n\n", .{ parsed.value.start_line, actual_end_line, total_lines });

    // Write numbered lines for requested range
    // Lines are 1-indexed, so convert to 0-indexed for array access
    const start_idx = parsed.value.start_line - 1;
    const end_idx = actual_end_line - 1;

    for (lines.items[start_idx .. end_idx + 1], start_idx..) |line, idx| {
        try writer.print("{d}: {s}\n", .{ idx + 1, line });
    }

    // Write footer with remaining lines info
    const lines_before = parsed.value.start_line - 1;
    const lines_after = total_lines - actual_end_line;

    if (lines_before > 0 or lines_after > 0) {
        try writer.writeAll("\n");
        if (lines_before > 0 and lines_after > 0) {
            try writer.print("--- {d} lines before (1-{d}) | {d} lines after ({d}-{d}) ---\n", .{
                lines_before,
                parsed.value.start_line - 1,
                lines_after,
                actual_end_line + 1,
                total_lines,
            });
        } else if (lines_before > 0) {
            try writer.print("--- {d} lines before (1-{d}) ---\n", .{ lines_before, parsed.value.start_line - 1 });
        } else {
            try writer.print("--- {d} lines remaining ({d}-{d}) ---\n", .{ lines_after, actual_end_line + 1, total_lines });
        }
    }

    try writer.writeAll("```");

    const formatted = try formatted_output.toOwnedSlice(allocator);
    defer allocator.free(formatted);

    // Mark file as read (enables editing this file)
    try context.state.markFileAsRead(parsed.value.path);

    return ToolResult.ok(allocator, formatted, start_time, null);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct {
        path: []const u8,
        start_line: usize,
        end_line: usize,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Block absolute paths
    if (std.mem.startsWith(u8, parsed.value.path, "/")) return false;

    // Block directory traversal
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) return false;

    // Block empty paths
    if (parsed.value.path.len == 0) return false;

    // Validate line numbers
    if (parsed.value.start_line == 0) return false;
    if (parsed.value.start_line > parsed.value.end_line) return false;

    // Validate line range
    const requested_lines = parsed.value.end_line - parsed.value.start_line + 1;
    if (requested_lines > MAX_LINE_RANGE) return false;

    return true;
}
