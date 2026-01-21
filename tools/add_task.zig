// Add Task Tool - Creates a new task with full options
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
const TaskPriority = task_store.TaskPriority;
const TaskType = task_store.TaskType;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "add_task"),
                .description = try allocator.dupe(u8, "Create a new task. Supports priorities (0-4, lower=higher), types (task/bug/feature/research), labels, and blocking dependencies."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "title": {
                    \\      "type": "string",
                    \\      "description": "Task title (required)"
                    \\    },
                    \\    "description": {
                    \\      "type": "string",
                    \\      "description": "Detailed task description"
                    \\    },
                    \\    "priority": {
                    \\      "type": "integer",
                    \\      "description": "Priority 0-4 (0=critical, 2=medium default, 4=wishlist)"
                    \\    },
                    \\    "type": {
                    \\      "type": "string",
                    \\      "enum": ["task", "bug", "feature", "research"],
                    \\      "description": "Task type (default: task)"
                    \\    },
                    \\    "labels": {
                    \\      "type": "array",
                    \\      "items": {"type": "string"},
                    \\      "description": "Labels/tags for the task"
                    \\    },
                    \\    "parent": {
                    \\      "type": "string",
                    \\      "description": "Parent task ID (for subtasks under a molecule/epic)"
                    \\    },
                    \\    "blocks": {
                    \\      "type": "array",
                    \\      "items": {"type": "string"},
                    \\      "description": "Task IDs that this task will block"
                    \\    }
                    \\  },
                    \\  "required": ["title"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "add_task",
            .description = "Create a new task",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Get task store from context
    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Parse arguments
    const Args = struct {
        title: []const u8,
        description: ?[]const u8 = null,
        priority: ?i64 = null,
        type: ?[]const u8 = null,
        labels: ?[]const []const u8 = null,
        parent: ?[]const u8 = null,
        blocks: ?[]const []const u8 = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Validate title
    if (args.title.len == 0) {
        return ToolResult.err(allocator, .invalid_arguments, "Title cannot be empty", start_time);
    }

    // Parse priority
    const priority = if (args.priority) |p|
        TaskPriority.fromInt(@intCast(@min(4, @max(0, p))))
    else
        TaskPriority.medium;

    // Parse task type
    const task_type = if (args.type) |t|
        TaskType.fromString(t) orelse TaskType.task
    else
        TaskType.task;

    // Parse parent ID
    var parent_id: ?task_store.TaskId = null;
    if (args.parent) |parent_str| {
        if (parent_str.len == 8) {
            parent_id = task_store.TaskStore.parseId(parent_str) catch null;
        }
    }

    // Parse blocking task IDs
    var blocks_list = std.ArrayListUnmanaged(task_store.TaskId){};
    defer blocks_list.deinit(allocator);

    if (args.blocks) |block_ids| {
        for (block_ids) |bid| {
            if (bid.len == 8) {
                if (task_store.TaskStore.parseId(bid)) |id| {
                    try blocks_list.append(allocator, id);
                } else |_| {}
            }
        }
    }

    // Create the task
    const task_id = store.createTask(.{
        .title = args.title,
        .description = args.description,
        .priority = priority,
        .task_type = task_type,
        .labels = args.labels,
        .parent_id = parent_id,
        .blocks = if (blocks_list.items.len > 0) blocks_list.items else null,
    }) catch |err| {
        const msg = switch (err) {
            error.TaskIdCollision => "Task ID collision (please retry)",
            error.SourceTaskNotFound => "Blocking task not found",
            error.DestTaskNotFound => "Target task not found",
            error.SelfDependency => "Cannot create self-dependency",
            else => "Failed to create task",
        };
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Return JSON result
    const result_msg = try std.fmt.allocPrint(allocator, "{{\"task_id\": \"{s}\", \"status\": \"pending\", \"priority\": {d}}}", .{
        &task_id,
        priority.toInt(),
    });
    defer allocator.free(result_msg);

    return ToolResult.ok(allocator, result_msg, start_time, null);
}
