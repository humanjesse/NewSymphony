// Get Session Status Tool - Comprehensive session status for main agent
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

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_session_status"),
                .description = try allocator.dupe(u8, "Get comprehensive session status: task counts, current task, ready queue, and recent activity. Use to report progress to user."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "include_recent": {
                    \\      "type": "integer",
                    \\      "description": "Number of recently completed tasks to include (default 5)"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_session_status",
            .description = "Get comprehensive session status",
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
    var include_recent: usize = 5;
    if (args_json.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("include_recent")) |v| {
                if (v == .integer) {
                    include_recent = @intCast(@max(1, @min(20, v.integer)));
                }
            }
        }
    }

    // Response structs for JSON serialization
    const TaskCounts = struct {
        total: usize,
        pending: usize,
        in_progress: usize,
        completed: usize,
        blocked: usize,
    };

    const CurrentTask = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        description: ?[]const u8 = null,
    };

    const ReadyTask = struct {
        id: []const u8,
        title: []const u8,
        priority: u8,
    };

    const BlockedTask = struct {
        id: []const u8,
        title: []const u8,
        blocked_reason: ?[]const u8 = null,
    };

    const CompletedTask = struct {
        id: []const u8,
        title: []const u8,
        completed_at: i64,
    };

    const InProgressTask = struct {
        id: []const u8,
        title: []const u8,
    };

    const Response = struct {
        tasks: TaskCounts,
        current_task: ?CurrentTask,
        ready_tasks: []const ReadyTask,
        blocked_tasks: []const BlockedTask,
        recently_completed: []const CompletedTask,
        in_progress_tasks: []const InProgressTask,
        session_id: ?[]const u8 = null,
        session_start: ?i64 = null,
        session_duration_minutes: ?i64 = null,
    };

    // Build task counts
    const counts = store.getTaskCounts();
    const total = counts.pending + counts.in_progress + counts.completed + counts.blocked;

    // Build current task
    var current_task: ?CurrentTask = null;
    var current_task_id_buf: [8]u8 = undefined;
    if (store.getCurrentTaskId()) |cid| {
        if (store.tasks.get(cid)) |task| {
            @memcpy(&current_task_id_buf, &task.id);
            current_task = .{
                .id = &current_task_id_buf,
                .title = task.title,
                .status = task.status.toString(),
                .description = task.description,
            };
        }
    }

    // Build ready tasks array
    var ready_tasks_list = std.ArrayListUnmanaged(ReadyTask){};
    defer ready_tasks_list.deinit(allocator);

    const ready = store.getReadyTasks() catch &[_]task_store.Task{};
    defer allocator.free(ready);

    // We need to store the id copies
    var ready_id_bufs = try allocator.alloc([8]u8, ready.len);
    defer allocator.free(ready_id_bufs);

    for (ready, 0..) |task, i| {
        @memcpy(&ready_id_bufs[i], &task.id);
        try ready_tasks_list.append(allocator, .{
            .id = &ready_id_bufs[i],
            .title = task.title,
            .priority = task.priority.toInt(),
        });
    }

    // Build blocked tasks array
    var blocked_tasks_list = std.ArrayListUnmanaged(BlockedTask){};
    defer blocked_tasks_list.deinit(allocator);

    const blocked = store.getTasksWithCommentPrefix("BLOCKED:") catch &[_]task_store.Task{};
    defer allocator.free(blocked);

    var blocked_id_bufs = try allocator.alloc([8]u8, blocked.len);
    defer allocator.free(blocked_id_bufs);

    for (blocked, 0..) |task, i| {
        @memcpy(&blocked_id_bufs[i], &task.id);

        // Find the most recent BLOCKED: comment
        var blocked_reason: ?[]const u8 = null;
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

        try blocked_tasks_list.append(allocator, .{
            .id = &blocked_id_bufs[i],
            .title = task.title,
            .blocked_reason = blocked_reason,
        });
    }

    // Build recently completed tasks
    var completed_tasks = std.ArrayListUnmanaged(task_store.Task){};
    defer completed_tasks.deinit(allocator);

    var iter = store.tasks.valueIterator();
    while (iter.next()) |task| {
        if (task.status == .completed and task.completed_at != null) {
            try completed_tasks.append(allocator, task.*);
        }
    }

    std.mem.sort(task_store.Task, completed_tasks.items, {}, struct {
        fn cmp(_: void, a: task_store.Task, b: task_store.Task) bool {
            return (a.completed_at orelse 0) > (b.completed_at orelse 0);
        }
    }.cmp);

    const show_count = @min(include_recent, completed_tasks.items.len);
    var recently_completed_list = std.ArrayListUnmanaged(CompletedTask){};
    defer recently_completed_list.deinit(allocator);

    var completed_id_bufs = try allocator.alloc([8]u8, show_count);
    defer allocator.free(completed_id_bufs);

    for (completed_tasks.items[0..show_count], 0..) |task, i| {
        @memcpy(&completed_id_bufs[i], &task.id);
        try recently_completed_list.append(allocator, .{
            .id = &completed_id_bufs[i],
            .title = task.title,
            .completed_at = task.completed_at orelse 0,
        });
    }

    // Build in-progress tasks
    var in_progress_list = std.ArrayListUnmanaged(InProgressTask){};
    defer in_progress_list.deinit(allocator);

    var in_progress_count: usize = 0;
    var iter2 = store.tasks.valueIterator();
    while (iter2.next()) |task| {
        if (task.status == .in_progress) in_progress_count += 1;
    }

    var in_progress_id_bufs = try allocator.alloc([8]u8, in_progress_count);
    defer allocator.free(in_progress_id_bufs);

    var ip_idx: usize = 0;
    var iter3 = store.tasks.valueIterator();
    while (iter3.next()) |task| {
        if (task.status == .in_progress) {
            @memcpy(&in_progress_id_bufs[ip_idx], &task.id);
            try in_progress_list.append(allocator, .{
                .id = &in_progress_id_bufs[ip_idx],
                .title = task.title,
            });
            ip_idx += 1;
        }
    }

    // Session metadata
    var session_duration_minutes: ?i64 = null;
    if (store.session_started_at) |start| {
        const now = std.time.timestamp();
        session_duration_minutes = @divFloor(now - start, 60);
    }

    // Build response and serialize
    const response = Response{
        .tasks = .{
            .total = total,
            .pending = counts.pending,
            .in_progress = counts.in_progress,
            .completed = counts.completed,
            .blocked = counts.blocked,
        },
        .current_task = current_task,
        .ready_tasks = ready_tasks_list.items,
        .blocked_tasks = blocked_tasks_list.items,
        .recently_completed = recently_completed_list.items,
        .in_progress_tasks = in_progress_list.items,
        .session_id = store.session_id,
        .session_start = store.session_started_at,
        .session_duration_minutes = session_duration_minutes,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
