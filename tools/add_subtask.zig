// Add Subtask Tool - Create a child task under a parent
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
const SubtaskInfo = struct {
    id: []const u8,
    title: []const u8,
    parent_id: []const u8,
};

const Response = struct {
    created: bool,
    subtask: SubtaskInfo,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "add_subtask"),
                .description = try allocator.dupe(u8, "Create a subtask under a parent task. Defaults to current task as parent."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "title": {
                    \\      "type": "string",
                    \\      "description": "Title of the subtask"
                    \\    },
                    \\    "parent_id": {
                    \\      "type": "string",
                    \\      "description": "Parent task ID. Defaults to current task if not specified."
                    \\    },
                    \\    "description": {
                    \\      "type": "string",
                    \\      "description": "Optional description of the subtask"
                    \\    }
                    \\  },
                    \\  "required": ["title"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "add_subtask",
            .description = "Add a subtask",
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

    const title = if (parsed.value.object.get("title")) |v|
        if (v == .string) v.string else null
    else
        null;

    if (title == null or title.?.len == 0) {
        return ToolResult.err(allocator, .invalid_arguments, "title is required", start_time);
    }

    const description = if (parsed.value.object.get("description")) |v|
        if (v == .string) v.string else null
    else
        null;

    // Get parent_id - either from args or current task
    var parent_id: task_store.TaskId = undefined;

    if (parsed.value.object.get("parent_id")) |v| {
        if (v == .string and v.string.len == 8) {
            @memcpy(&parent_id, v.string[0..8]);
        } else {
            return ToolResult.err(allocator, .invalid_arguments, "parent_id must be 8 characters", start_time);
        }
    } else {
        // Use current task
        if (store.getCurrentTaskId()) |cid| {
            parent_id = cid;
        } else {
            return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify parent_id explicitly.", start_time);
        }
    }

    // Verify parent exists
    if (!store.tasks.contains(parent_id)) {
        return ToolResult.err(allocator, .internal_error, "Parent task not found", start_time);
    }

    // Create the subtask
    const subtask_id = store.createTask(.{
        .title = title.?,
        .description = description,
        .parent_id = parent_id,
        .task_type = .task,
    }) catch |err| {
        const msg = switch (err) {
            error.TaskIdCollision => "Task ID collision - try again",
            else => "Failed to create subtask",
        };
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Build response
    const response = Response{
        .created = true,
        .subtask = .{
            .id = &subtask_id,
            .title = title.?,
            .parent_id = &parent_id,
        },
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
