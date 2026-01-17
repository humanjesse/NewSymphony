// Get Blocked Tasks Tool - Find tasks that are blocked with reasons
// Used by planner to query which tasks need decomposition
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");
const html_utils = @import("html_utils");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_blocked_tasks"),
                .description = try allocator.dupe(u8, "Get tasks that are blocked with reasons. Returns tasks that need decomposition by planner."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {}
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_blocked_tasks",
            .description = "Get blocked tasks with reasons",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, _: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Get blocked tasks that have a reason (need decomposition)
    const blocked_tasks = store.getBlockedTasksWithReasons() catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get blocked tasks", start_time);
    };
    defer allocator.free(blocked_tasks);

    // Build JSON response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"blocked\": [");

    for (blocked_tasks, 0..) |task, i| {
        if (i > 0) try json.append(allocator, ',');

        // Escape title for JSON
        const escaped_title = try html_utils.escapeJSON(allocator, task.title);
        defer allocator.free(escaped_title);

        // Escape blocked_reason for JSON
        const escaped_reason = if (task.blocked_reason) |reason|
            try html_utils.escapeJSON(allocator, reason)
        else
            try allocator.dupe(u8, "");
        defer allocator.free(escaped_reason);

        try json.writer(allocator).print(
            "{{\"id\":\"{s}\",\"title\":\"{s}\",\"priority\":{d},\"type\":\"{s}\",\"blocked_reason\":\"{s}\"}}",
            .{
                &task.id,
                escaped_title,
                task.priority.toInt(),
                task.task_type.toString(),
                escaped_reason,
            },
        );
    }

    // Add count
    try json.writer(allocator).print("], \"count\": {d}}}", .{blocked_tasks.len});

    const result = try allocator.dupe(u8, json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
