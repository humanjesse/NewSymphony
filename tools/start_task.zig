// Start Task Tool - Explicitly switch to working on a specific task
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

// Response structs for JSON serialization
const TaskInfo = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: u8,
};

const Response = struct {
    started: bool,
    task: TaskInfo,
    reason: ?[]const u8 = null,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "start_task"),
                .description = try allocator.dupe(u8, "Start working on a specific task. Sets it as current and marks as in_progress. Optionally provide a reason to add an audit trail comment."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "The 8-character task ID to start working on"
                    \\    },
                    \\    "reason": {
                    \\      "type": "string",
                    \\      "description": "Optional reason for starting this task (adds 'QUEUED: reason' comment for audit trail)"
                    \\    }
                    \\  },
                    \\  "required": ["task_id"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "start_task",
            .description = "Start working on a task",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, args_json: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Parse arguments
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const task_id_str = if (parsed.value.object.get("task_id")) |v|
        if (v == .string) v.string else null
    else
        null;

    const reason = if (parsed.value.object.get("reason")) |v|
        if (v == .string) v.string else null
    else
        null;

    if (task_id_str == null or task_id_str.?.len != 8) {
        return ToolResult.err(allocator, .invalid_arguments, "task_id must be an 8-character string", start_time);
    }

    var task_id: task_store.TaskId = undefined;
    @memcpy(&task_id, task_id_str.?[0..8]);

    // Check if task is a molecule - molecules can't be started directly
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    if (try store.getTaskWithAllocator(task_id, task_alloc)) |task| {
        if (task.task_type == .molecule) {
            return ToolResult.err(allocator, .invalid_arguments, "Cannot start a molecule directly. Use list_tasks(ready_only=true) to find actionable tasks.", start_time);
        }
    } else {
        return ToolResult.err(allocator, .internal_error, "Task not found", start_time);
    }

    // Set as current task
    store.setCurrentTask(task_id) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to set current task", start_time);
    };

    // If reason provided, add audit trail comment
    if (reason) |r| {
        const agent_name = context.current_agent_name orelse "unknown";
        const queued_comment = try std.fmt.allocPrint(allocator, "QUEUED: {s}", .{r});
        defer allocator.free(queued_comment);
        store.addComment(task_id, agent_name, queued_comment) catch {
            // Non-fatal - continue even if comment fails
        };
    }

    // Get the task for response (reusing task_alloc from above - arena auto-freed when tool returns)
    const task = (try store.getTaskWithAllocator(task_id, task_alloc)) orelse {
        return ToolResult.err(allocator, .internal_error, "Task disappeared after setting as current", start_time);
    };
    // No defer needed - arena handles cleanup

    // Build response
    const response = Response{
        .started = true,
        .task = .{
            .id = &task.id,
            .title = task.title,
            .status = task.status.toString(),
            .priority = task.priority.toInt(),
        },
        .reason = reason,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
