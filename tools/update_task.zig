// Update Task Tool - Modify properties of an existing task
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;
const TaskStore = task_store.TaskStore;
const TaskStatus = task_store.TaskStatus;
const TaskPriority = task_store.TaskPriority;
const TaskType = task_store.TaskType;

// Response structs for JSON serialization
const TaskInfo = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: []const u8,
    type: []const u8,
};

const Response = struct {
    updated: bool,
    task: TaskInfo,
    changes: []const []const u8,
    unblocked_count: ?usize = null,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "update_task"),
                .description = try allocator.dupe(u8, "Update properties of an existing task. Only provided fields are changed."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "The 8-character task ID to update"
                    \\    },
                    \\    "title": {
                    \\      "type": "string",
                    \\      "description": "New title for the task"
                    \\    },
                    \\    "priority": {
                    \\      "type": "string",
                    \\      "enum": ["low", "medium", "high", "critical"],
                    \\      "description": "New priority level"
                    \\    },
                    \\    "task_type": {
                    \\      "type": "string",
                    \\      "enum": ["task", "bug", "feature", "research", "molecule"],
                    \\      "description": "New task type (cannot change to/from wisp)"
                    \\    },
                    \\    "status": {
                    \\      "type": "string",
                    \\      "enum": ["pending", "in_progress", "blocked", "completed", "cancelled"],
                    \\      "description": "New status (completed triggers cascade unblocking)"
                    \\    }
                    \\  },
                    \\  "required": ["task_id"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "update_task",
            .description = "Update task properties",
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
    const parsed = json.parseFromSlice(json.Value, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // Get required task_id
    const task_id_str = if (parsed.value.object.get("task_id")) |v|
        if (v == .string) v.string else null
    else
        null;

    if (task_id_str == null or task_id_str.?.len != 8) {
        return ToolResult.err(allocator, .invalid_arguments, "task_id must be an 8-character string", start_time);
    }

    var task_id: task_store.TaskId = undefined;
    @memcpy(&task_id, task_id_str.?[0..8]);

    // Build UpdateTaskParams from provided fields
    var update_params = TaskStore.UpdateTaskParams{};
    var changes = std.ArrayListUnmanaged([]const u8){};
    defer changes.deinit(allocator);

    // Parse title if provided
    if (parsed.value.object.get("title")) |v| {
        if (v == .string and v.string.len > 0) {
            update_params.title = v.string;
            try changes.append(allocator, "title");
        }
    }

    // Parse priority if provided
    if (parsed.value.object.get("priority")) |v| {
        if (v == .string) {
            const new_priority: ?TaskPriority = if (std.mem.eql(u8, v.string, "low"))
                .low
            else if (std.mem.eql(u8, v.string, "medium"))
                .medium
            else if (std.mem.eql(u8, v.string, "high"))
                .high
            else if (std.mem.eql(u8, v.string, "critical"))
                .critical
            else
                null;

            if (new_priority) |prio| {
                update_params.priority = prio;
                try changes.append(allocator, "priority");
            } else {
                return ToolResult.err(allocator, .invalid_arguments, "Invalid priority value", start_time);
            }
        }
    }

    // Parse task_type if provided
    if (parsed.value.object.get("task_type")) |v| {
        if (v == .string) {
            const new_type: ?TaskType = if (std.mem.eql(u8, v.string, "task"))
                .task
            else if (std.mem.eql(u8, v.string, "bug"))
                .bug
            else if (std.mem.eql(u8, v.string, "feature"))
                .feature
            else if (std.mem.eql(u8, v.string, "research"))
                .research
            else if (std.mem.eql(u8, v.string, "molecule"))
                .molecule
            else if (std.mem.eql(u8, v.string, "wisp"))
                .wisp
            else
                null;

            if (new_type) |tt| {
                update_params.task_type = tt;
                try changes.append(allocator, "task_type");
            } else {
                return ToolResult.err(allocator, .invalid_arguments, "Invalid task_type value", start_time);
            }
        }
    }

    // Parse status if provided
    if (parsed.value.object.get("status")) |v| {
        if (v == .string) {
            const new_status: ?TaskStatus = if (std.mem.eql(u8, v.string, "pending"))
                .pending
            else if (std.mem.eql(u8, v.string, "in_progress"))
                .in_progress
            else if (std.mem.eql(u8, v.string, "blocked"))
                .blocked
            else if (std.mem.eql(u8, v.string, "completed"))
                .completed
            else if (std.mem.eql(u8, v.string, "cancelled"))
                .cancelled
            else
                null;

            if (new_status) |status| {
                update_params.status = status;
                try changes.append(allocator, "status");
            } else {
                return ToolResult.err(allocator, .invalid_arguments, "Invalid status value", start_time);
            }
        }
    }

    // Check if any changes were requested
    if (changes.items.len == 0) {
        return ToolResult.err(allocator, .invalid_arguments, "No valid fields to update", start_time);
    }

    // Execute batch update (all changes in single transaction)
    const complete_result = store.updateTask(task_id, update_params) catch |err| {
        return switch (err) {
            error.TaskNotFound => ToolResult.err(allocator, .not_found, "Task not found", start_time),
            error.CannotUpdateWisp => ToolResult.err(allocator, .invalid_arguments, "Cannot update wisp tasks - they are ephemeral", start_time),
            error.CannotChangeWispType => ToolResult.err(allocator, .invalid_arguments, "Cannot change task type to or from wisp", start_time),
            error.OutOfMemory => ToolResult.err(allocator, .internal_error, "Out of memory during update", start_time),
            else => ToolResult.err(allocator, .internal_error, "Failed to update task", start_time),
        };
    };
    defer if (complete_result) |cr| allocator.free(cr.unblocked);

    const unblocked_count: usize = if (complete_result) |cr| cr.unblocked.len else 0;

    // Get updated task for response
    const updated_task = (try store.getTask(task_id)) orelse {
        return ToolResult.err(allocator, .internal_error, "Task disappeared after update", start_time);
    };
    defer {
        var ut = updated_task;
        ut.deinit(allocator);
    }

    const prio_str = switch (updated_task.priority) {
        .critical => "critical",
        .high => "high",
        .medium => "medium",
        .low => "low",
        .wishlist => "wishlist",
    };

    const response = Response{
        .updated = true,
        .task = .{
            .id = &updated_task.id,
            .title = updated_task.title,
            .status = updated_task.status.toString(),
            .priority = prio_str,
            .type = updated_task.task_type.toString(),
        },
        .changes = changes.items,
        .unblocked_count = if (unblocked_count > 0) unblocked_count else null,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
