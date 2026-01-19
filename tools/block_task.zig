// Block Task Tool - Mark a task as blocked with a reason
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
const BlockedTask = struct {
    id: []const u8,
    title: []const u8,
};

const Response = struct {
    blocked: bool,
    task: BlockedTask,
    reason: []const u8,
    current_task_cleared: bool,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "block_task"),
                .description = try allocator.dupe(u8, "Mark a task as blocked. Optionally specify what's blocking it."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "Task to block. Defaults to current task if not specified."
                    \\    },
                    \\    "reason": {
                    \\      "type": "string",
                    \\      "description": "Why this task is blocked"
                    \\    },
                    \\    "blocked_by": {
                    \\      "type": "string",
                    \\      "description": "Task ID that is blocking this task"
                    \\    }
                    \\  },
                    \\  "required": ["reason"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "block_task",
            .description = "Block a task",
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

    const reason = if (parsed.value.object.get("reason")) |v|
        if (v == .string) v.string else null
    else
        null;

    if (reason == null) {
        return ToolResult.err(allocator, .invalid_arguments, "reason is required", start_time);
    }

    // Get task_id - either from args or current task
    var task_id: task_store.TaskId = undefined;
    var is_current_task = false;

    if (parsed.value.object.get("task_id")) |v| {
        if (v == .string and v.string.len == 8) {
            @memcpy(&task_id, v.string[0..8]);
        } else {
            return ToolResult.err(allocator, .invalid_arguments, "task_id must be 8 characters", start_time);
        }
    } else {
        // Use current task
        if (store.getCurrentTaskId()) |cid| {
            task_id = cid;
            is_current_task = true;
        } else {
            return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
        }
    }

    // Get the task
    const task = store.getTask(task_id) orelse {
        return ToolResult.err(allocator, .internal_error, "Task not found", start_time);
    };

    // Update status to blocked
    store.updateStatus(task_id, .blocked) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to update task status", start_time);
    };

    // Add a comment with the block reason (Beads philosophy)
    const agent_name = context.current_agent_name orelse "unknown";
    const block_comment = try std.fmt.allocPrint(allocator, "BLOCKED: {s}", .{reason.?});
    defer allocator.free(block_comment);
    store.addComment(task_id, agent_name, block_comment) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to add block comment", start_time);
    };

    // If blocked_by is specified, add a dependency
    if (parsed.value.object.get("blocked_by")) |v| {
        if (v == .string and v.string.len == 8) {
            var blocker_id: task_store.TaskId = undefined;
            @memcpy(&blocker_id, v.string[0..8]);
            store.addDependency(blocker_id, task_id, .blocks) catch {
                // Dependency might already exist or task might not exist
            };
        }
    }

    // Clear current task if we blocked it
    if (is_current_task) {
        store.clearCurrentTask();
    }

    // Persist to database if available
    // Note: block_task needs to save the task status change, so we use saveTask
    // The comment is already in the in-memory store and will be saved with the task
    if (context.task_db) |db| {
        if (store.getTask(task_id)) |t| {
            db.saveTask(t) catch |err| {
                std.log.warn("Failed to persist blocked task to SQLite: {}", .{err});
            };
        }
    }

    // Build response
    const response = Response{
        .blocked = true,
        .task = .{
            .id = &task_id,
            .title = task.title,
        },
        .reason = reason.?,
        .current_task_cleared = is_current_task,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
