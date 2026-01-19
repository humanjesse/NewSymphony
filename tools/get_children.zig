// Get Children Tool - Get immediate children of a molecule/epic
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

// Response structs for JSON serialization
const ChildTask = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: u8,
    type: []const u8,
};

const Response = struct {
    parent_id: []const u8,
    children: []const ChildTask,
    count: usize,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_children"),
                .description = try allocator.dupe(u8, "Get immediate children of a molecule/epic task. Returns all tasks whose parent_id matches the given task."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "8-character task ID of the parent molecule/epic"
                    \\    }
                    \\  },
                    \\  "required": ["task_id"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_children",
            .description = "Get children of a task",
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

    // Get children
    const children = store.getChildren(task_id) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get children", start_time);
    };
    defer allocator.free(children);

    // Build children array
    var children_array = std.ArrayListUnmanaged(ChildTask){};
    defer children_array.deinit(allocator);

    for (children) |child| {
        try children_array.append(allocator, .{
            .id = &child.id,
            .title = child.title,
            .status = child.status.toString(),
            .priority = child.priority.toInt(),
            .type = child.task_type.toString(),
        });
    }

    const response = Response{
        .parent_id = &task_id,
        .children = children_array.items,
        .count = children.len,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
