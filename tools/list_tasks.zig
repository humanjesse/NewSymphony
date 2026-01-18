// List Tasks Tool - Query tasks with filters
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
const TaskStore = task_store.TaskStore;
const TaskStatus = task_store.TaskStatus;
const TaskPriority = task_store.TaskPriority;
const TaskType = task_store.TaskType;
const TaskFilter = task_store.TaskFilter;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "list_tasks"),
                .description = try allocator.dupe(u8, "List tasks with optional filters. Can filter by status, priority, type, parent, or label."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "status": {
                    \\      "type": "string",
                    \\      "enum": ["pending", "in_progress", "completed", "blocked", "cancelled"],
                    \\      "description": "Filter by status"
                    \\    },
                    \\    "priority": {
                    \\      "type": "integer",
                    \\      "description": "Filter by priority (0-4)"
                    \\    },
                    \\    "type": {
                    \\      "type": "string",
                    \\      "enum": ["task", "bug", "feature", "research", "molecule"],
                    \\      "description": "Filter by task type"
                    \\    },
                    \\    "parent": {
                    \\      "type": "string",
                    \\      "description": "Filter by parent task ID"
                    \\    },
                    \\    "label": {
                    \\      "type": "string",
                    \\      "description": "Filter by label"
                    \\    },
                    \\    "ready_only": {
                    \\      "type": "boolean",
                    \\      "description": "Only show ready tasks (pending with no blockers)"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "list_tasks",
            .description = "List tasks with filters",
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
        status: ?[]const u8 = null,
        priority: ?i64 = null,
        type: ?[]const u8 = null,
        parent: ?[]const u8 = null,
        label: ?[]const u8 = null,
        ready_only: ?bool = null,
    };

    var filter = TaskFilter{};

    if (arguments.len > 2) { // Not empty "{}"
        const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{
            .ignore_unknown_fields = true,
        }) catch {
            return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
        };
        defer parsed.deinit();

        const args = parsed.value;

        if (args.status) |s| {
            filter.status = TaskStatus.fromString(s);
        }
        if (args.priority) |p| {
            filter.priority = TaskPriority.fromInt(@intCast(@min(4, @max(0, p))));
        }
        if (args.type) |t| {
            filter.task_type = TaskType.fromString(t);
        }
        if (args.parent) |parent_str| {
            if (parent_str.len == 8) {
                filter.parent_id = TaskStore.parseId(parent_str) catch null;
            }
        }
        if (args.label) |l| {
            filter.label = l;
        }
        if (args.ready_only) |r| {
            filter.ready_only = r;
        }
    }

    // Get tasks
    const tasks = store.listTasks(filter) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to list tasks", start_time);
    };
    defer allocator.free(tasks);

    // Build JSON response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"tasks\": [");

    for (tasks, 0..) |task, i| {
        if (i > 0) try json.append(allocator, ',');

        // Escape title for JSON
        const escaped_title = try html_utils.escapeJSON(allocator, task.title);
        defer allocator.free(escaped_title);

        // Base task info
        try json.writer(allocator).print(
            "{{\"id\":\"{s}\",\"title\":\"{s}\",\"status\":\"{s}\",\"priority\":{d},\"type\":\"{s}\",\"blocked_by\":{d}",
            .{
                &task.id,
                escaped_title,
                task.status.toString(),
                task.priority.toInt(),
                task.task_type.toString(),
                task.blocked_by_count,
            },
        );

        // Add blocked_reason from comments if task is blocked (Beads philosophy)
        if (task.status == .blocked) {
            // Find most recent BLOCKED: comment
            var j = task.comments.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.startsWith(u8, task.comments[j].content, "BLOCKED:")) {
                    var blocked_reason = task.comments[j].content[8..];
                    // Trim leading whitespace
                    while (blocked_reason.len > 0 and blocked_reason[0] == ' ') {
                        blocked_reason = blocked_reason[1..];
                    }
                    const escaped_reason = try html_utils.escapeJSON(allocator, blocked_reason);
                    defer allocator.free(escaped_reason);
                    try json.writer(allocator).print(",\"blocked_reason\":\"{s}\"", .{escaped_reason});
                    break;
                }
            }
        }

        // Close the object
        try json.append(allocator, '}');
    }

    // Add summary
    const counts = store.getTaskCounts();
    try json.writer(allocator).print("], \"total\": {d}, \"summary\": {{\"pending\": {d}, \"in_progress\": {d}, \"completed\": {d}, \"blocked\": {d}}}}}", .{
        tasks.len,
        counts.pending,
        counts.in_progress,
        counts.completed,
        counts.blocked,
    });

    const result = try allocator.dupe(u8, json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
