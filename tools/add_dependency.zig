// Add Dependency Tool - Create relationships between tasks
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
const DependencyType = task_store.DependencyType;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "add_dependency"),
                .description = try allocator.dupe(u8, "Create a dependency between tasks. Type 'blocks' means src must complete before dst can start."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "src": {
                    \\      "type": "string",
                    \\      "description": "Source task ID (the blocker)"
                    \\    },
                    \\    "dst": {
                    \\      "type": "string",
                    \\      "description": "Destination task ID (the blocked task)"
                    \\    },
                    \\    "type": {
                    \\      "type": "string",
                    \\      "enum": ["blocks", "parent", "related", "discovered"],
                    \\      "description": "Dependency type (default: blocks)"
                    \\    }
                    \\  },
                    \\  "required": ["src", "dst"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "add_dependency",
            .description = "Add task dependency",
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
        src: []const u8,
        dst: []const u8,
        type: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{
        .ignore_unknown_fields = true,
    }) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Parse task IDs
    if (args.src.len != 8) {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid source task ID (must be 8 characters)", start_time);
    }
    if (args.dst.len != 8) {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid destination task ID (must be 8 characters)", start_time);
    }

    const src_id = TaskStore.parseId(args.src) catch {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid source task ID format", start_time);
    };

    const dst_id = TaskStore.parseId(args.dst) catch {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid destination task ID format", start_time);
    };

    // Parse dependency type
    const dep_type = if (args.type) |t|
        DependencyType.fromString(t) orelse DependencyType.blocks
    else
        DependencyType.blocks;

    // Add the dependency
    store.addDependency(src_id, dst_id, dep_type) catch |err| {
        const msg = switch (err) {
            error.SourceTaskNotFound => "Source task not found",
            error.DestTaskNotFound => "Destination task not found",
            error.SelfDependency => "Cannot create self-dependency",
            error.CircularDependency => "Would create circular dependency",
            error.DependencyExists => "Dependency already exists",
            else => "Failed to add dependency",
        };
        return ToolResult.err(allocator, .invalid_arguments, msg, start_time);
    };

    // Persist to database if available
    if (context.task_db) |db| {
        db.saveDependency(&.{
            .src_id = src_id,
            .dst_id = dst_id,
            .dep_type = dep_type,
            .weight = 1.0,
        }) catch |err| {
            std.log.warn("Failed to persist dependency to SQLite: {}", .{err});
        };
    }

    // Return JSON result
    const result_msg = try std.fmt.allocPrint(allocator, "{{\"src\": \"{s}\", \"dst\": \"{s}\", \"type\": \"{s}\", \"success\": true}}", .{
        &src_id,
        &dst_id,
        dep_type.toString(),
    });
    defer allocator.free(result_msg);

    return ToolResult.ok(allocator, result_msg, start_time, null);
}
