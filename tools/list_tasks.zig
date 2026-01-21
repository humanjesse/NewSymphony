// List Tasks Tool - Query tasks with filters
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

    // Get tasks using arena allocator (auto-freed when tool returns)
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    const tasks = store.listTasksWithAllocator(filter, task_alloc) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to list tasks", start_time);
    };
    // No defer needed - arena handles cleanup

    // Response structs for JSON serialization
    const TaskInfo = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        priority: u8,
        @"type": []const u8,
        blocked_by: usize,
        blocked_reason: ?[]const u8 = null,
    };

    const Summary = struct {
        pending: usize,
        in_progress: usize,
        completed: usize,
        blocked: usize,
    };

    const Response = struct {
        tasks: []const TaskInfo,
        total: usize,
        summary: Summary,
    };

    // Build task info array
    var task_infos = std.ArrayListUnmanaged(TaskInfo){};
    defer task_infos.deinit(allocator);

    // We need to store the id copies
    var id_bufs = try allocator.alloc([8]u8, tasks.len);
    defer allocator.free(id_bufs);

    for (tasks, 0..) |task, i| {
        @memcpy(&id_bufs[i], &task.id);

        // Find blocked_reason if task is blocked
        var blocked_reason: ?[]const u8 = null;
        if (task.status == .blocked) {
            var j = task.comments.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.startsWith(u8, task.comments[j].content, "BLOCKED:")) {
                    var reason = task.comments[j].content[8..];
                    while (reason.len > 0 and reason[0] == ' ') {
                        reason = reason[1..];
                    }
                    if (reason.len > 0) blocked_reason = reason;
                    break;
                }
            }
        }

        try task_infos.append(allocator, .{
            .id = &id_bufs[i],
            .title = task.title,
            .status = task.status.toString(),
            .priority = task.priority.toInt(),
            .@"type" = task.task_type.toString(),
            .blocked_by = task.blocked_by_count,
            .blocked_reason = blocked_reason,
        });
    }

    const counts = try store.getTaskCounts();

    const response = Response{
        .tasks = task_infos.items,
        .total = tasks.len,
        .summary = .{
            .pending = counts.pending,
            .in_progress = counts.in_progress,
            .completed = counts.completed,
            .blocked = counts.blocked,
        },
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
