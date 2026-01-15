// Get Epic Summary Tool - Get molecule/epic status with child task aggregation
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;
const TaskStore = task_store.TaskStore;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_epic_summary"),
                .description = try allocator.dupe(u8, "Get summary of a molecule/epic including child task counts, completion percentage, and status breakdown."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "8-character task ID of the molecule/epic"
                    \\    }
                    \\  },
                    \\  "required": ["task_id"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_epic_summary",
            .description = "Get epic/molecule summary",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Parse arguments
    const Args = struct {
        task_id: ?[]const u8 = null,
    };

    if (arguments.len <= 2) {
        return ToolResult.err(allocator, .invalid_arguments, "task_id is required", start_time);
    }

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const task_id_str = parsed.value.task_id orelse {
        return ToolResult.err(allocator, .invalid_arguments, "task_id is required", start_time);
    };

    if (task_id_str.len != 8) {
        return ToolResult.err(allocator, .invalid_arguments, "task_id must be 8 characters", start_time);
    }

    const task_id = TaskStore.parseId(task_id_str) catch {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid task ID format", start_time);
    };

    // Get epic summary
    const summary = store.getEpicSummary(task_id) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get epic summary", start_time);
    } orelse {
        return ToolResult.err(allocator, .not_found, "Task not found", start_time);
    };

    // Escape title
    var escaped_title = std.ArrayListUnmanaged(u8){};
    defer escaped_title.deinit(allocator);
    for (summary.task.title) |c| {
        switch (c) {
            '"' => try escaped_title.appendSlice(allocator, "\\\""),
            '\\' => try escaped_title.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_title.appendSlice(allocator, "\\n"),
            else => try escaped_title.append(allocator, c),
        }
    }

    // Build JSON response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(allocator);

    try json.writer(allocator).print(
        "{{\"id\":\"{s}\",\"title\":\"{s}\",\"status\":\"{s}\",\"type\":\"{s}\",\"is_epic\":{s},",
        .{
            &summary.task.id,
            escaped_title.items,
            summary.task.status.toString(),
            summary.task.task_type.toString(),
            if (summary.task.task_type == .molecule) "true" else "false",
        },
    );

    try json.writer(allocator).print(
        "\"children\":{{\"total\":{d},\"completed\":{d},\"in_progress\":{d},\"blocked\":{d},\"pending\":{d}}},",
        .{
            summary.total_children,
            summary.completed_children,
            summary.in_progress_children,
            summary.blocked_children,
            summary.total_children - summary.completed_children - summary.in_progress_children - summary.blocked_children,
        },
    );

    try json.writer(allocator).print(
        "\"completion_percent\":{d}}}",
        .{summary.completion_percent},
    );

    const result = try allocator.dupe(u8, json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
