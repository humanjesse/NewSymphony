// Get Siblings Tool - Get tasks with the same parent
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
const Sibling = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: u8,
};

const Response = struct {
    task_id: []const u8,
    parent_id: ?[]const u8,
    siblings: []const Sibling,
    count: usize,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_siblings"),
                .description = try allocator.dupe(u8, "Get sibling tasks (tasks with the same parent). Useful for understanding related work in an epic."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "8-character task ID to find siblings for"
                    \\    }
                    \\  },
                    \\  "required": ["task_id"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_siblings",
            .description = "Get sibling tasks",
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

    // Get the task first to find its parent
    const task = store.getTask(task_id) orelse {
        return ToolResult.err(allocator, .not_found, "Task not found", start_time);
    };

    // Get siblings
    const siblings = store.getSiblings(task_id) catch |err| {
        if (err == error.TaskNotFound) {
            return ToolResult.err(allocator, .not_found, "Task not found", start_time);
        }
        return ToolResult.err(allocator, .internal_error, "Failed to get siblings", start_time);
    };
    defer allocator.free(siblings);

    // Build siblings array
    var siblings_array = std.ArrayListUnmanaged(Sibling){};
    defer siblings_array.deinit(allocator);

    for (siblings) |sibling| {
        try siblings_array.append(allocator, .{
            .id = &sibling.id,
            .title = sibling.title,
            .status = sibling.status.toString(),
            .priority = sibling.priority.toInt(),
        });
    }

    // Store parent_id slice if present
    var parent_id_slice: ?[]const u8 = null;
    if (task.parent_id) |pid| {
        parent_id_slice = &pid;
    }

    const response = Response{
        .task_id = &task_id,
        .parent_id = parent_id_slice,
        .siblings = siblings_array.items,
        .count = siblings.len,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
