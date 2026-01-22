// Complete Task Tool - Mark task as done, cascade to dependents, auto-advance
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

// Response structs for JSON serialization
const CompletedTask = struct {
    id: []const u8,
    title: []const u8,
};

const NextTask = struct {
    id: []const u8,
    title: []const u8,
    priority: u8,
};

const Response = struct {
    completed: bool,
    task: CompletedTask,
    unblocked: []const []const u8,
    unblocked_count: usize,
    summary: ?[]const u8 = null,
    next_task: ?NextTask = null,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "complete_task"),
                .description = try allocator.dupe(u8, "Complete a task. Defaults to current task. Auto-advances to next ready task."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "Task to complete. Defaults to current task if not specified."
                    \\    },
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Brief summary of what was done"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "complete_task",
            .description = "Complete a task",
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
    var task_id: task_store.TaskId = undefined;
    var summary: ?[]const u8 = null;

    if (arguments.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, arguments, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();

            // Get task_id - either from args or current task
            if (p.value.object.get("task_id")) |v| {
                if (v == .string and v.string.len == 8) {
                    @memcpy(&task_id, v.string[0..8]);
                } else {
                    return ToolResult.err(allocator, .invalid_arguments, "task_id must be 8 characters", start_time);
                }
            } else {
                // Use current task
                task_id = store.getCurrentTaskId() orelse {
                    return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
                };
            }

            // Get optional summary
            if (p.value.object.get("summary")) |v| {
                if (v == .string) summary = v.string;
            }
        } else {
            // No args provided, use current task
            task_id = store.getCurrentTaskId() orelse {
                return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
            };
        }
    } else {
        // No args provided, use current task
        task_id = store.getCurrentTaskId() orelse {
            return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
        };
    }

    // Get task title before completion (using arena - auto-freed when tool returns)
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    const task = (try store.getTaskWithAllocator(task_id, task_alloc)) orelse {
        return ToolResult.err(allocator, .not_found, "Task not found", start_time);
    };
    // No defer needed - arena handles cleanup

    // Complete the task (automatically persisted to SQLite)
    const complete_result = store.completeTask(task_id) catch |err| {
        const msg = switch (err) {
            error.TaskNotFound => "Task not found",
            else => "Failed to complete task",
        };
        return ToolResult.err(allocator, .not_found, msg, start_time);
    };
    defer allocator.free(complete_result.unblocked);

    // Build unblocked IDs array
    var unblocked_ids = std.ArrayListUnmanaged([]const u8){};
    defer unblocked_ids.deinit(allocator);
    for (complete_result.unblocked) |unblocked_id| {
        try unblocked_ids.append(allocator, &unblocked_id);
    }

    // Auto-advance: get next ready task (using arena - auto-freed when tool returns)
    const ready_tasks = store.getReadyTasksWithAllocator(task_alloc) catch &[_]task_store.Task{};
    // No defer needed - arena handles cleanup

    var next_task: ?NextTask = null;
    if (ready_tasks.len > 0) {
        const next = ready_tasks[0];
        next_task = .{
            .id = &next.id,
            .title = next.title,
            .priority = next.priority.toInt(),
        };
    }

    const response = Response{
        .completed = true,
        .task = .{
            .id = task_id[0..],
            .title = task.title,
        },
        .unblocked = unblocked_ids.items,
        .unblocked_count = complete_result.unblocked.len,
        .summary = summary,
        .next_task = next_task,
    };

    const json_result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(json_result);

    return ToolResult.ok(allocator, json_result, start_time, null);
}
