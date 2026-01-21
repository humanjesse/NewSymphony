// Get Session Context Tool - Cold start recovery
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");
const git_sync = @import("git_sync");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Response structs for JSON serialization
const CurrentTask = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: u8,
};

const ReadyTask = struct {
    id: []const u8,
    title: []const u8,
    priority: u8,
};

const CompletedTask = struct {
    id: []const u8,
    title: []const u8,
    completed_at: i64,
};

const Counts = struct {
    pending: usize,
    in_progress: usize,
    completed: usize,
    blocked: usize,
};

const Response = struct {
    session_id: ?[]const u8 = null,
    current_task: ?CurrentTask = null,
    ready_tasks: []const ReadyTask,
    recently_completed: []const CompletedTask,
    counts: Counts,
    notes: ?[]const u8 = null,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_session_context"),
                .description = try allocator.dupe(u8, "Get context for cold start recovery. Returns session state, current task, ready queue, and notes."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "depth": {
                    \\      "type": "integer",
                    \\      "description": "How many recent completed tasks to include (default 3)"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_session_context",
            .description = "Get session context for cold start",
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
    var depth: usize = 3;
    if (args_json.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("depth")) |v| {
                if (v == .integer) {
                    depth = @intCast(@max(1, @min(10, v.integer)));
                }
            }
        }
    }

    // Build current task info
    var current_task: ?CurrentTask = null;
    var current_task_obj: ?task_store.Task = null;
    defer {
        if (current_task_obj) |*ct| {
            ct.deinit(allocator);
        }
    }
    if (store.getCurrentTaskId()) |cid| {
        if (try store.getTask(cid)) |task| {
            current_task_obj = task;
            current_task = .{
                .id = &task.id,
                .title = task.title,
                .status = task.status.toString(),
                .priority = task.priority.toInt(),
            };
        }
    }

    // Build ready tasks array
    const ready = store.getReadyTasks() catch &[_]task_store.Task{};
    defer {
        for (ready) |*r| {
            var task = r.*;
            task.deinit(allocator);
        }
        allocator.free(ready);
    }

    var ready_tasks = std.ArrayListUnmanaged(ReadyTask){};
    defer ready_tasks.deinit(allocator);

    for (ready) |task| {
        try ready_tasks.append(allocator, .{
            .id = &task.id,
            .title = task.title,
            .priority = task.priority.toInt(),
        });
    }

    // Build recently completed array from SQLite
    const completed_tasks_raw = try store.db.getTasksByStatus(.completed);
    defer {
        for (completed_tasks_raw) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(completed_tasks_raw);
    }

    // Sort by completion time (most recent first)
    std.mem.sort(task_store.Task, completed_tasks_raw, {}, struct {
        fn cmp(_: void, a: task_store.Task, b: task_store.Task) bool {
            return (a.completed_at orelse 0) > (b.completed_at orelse 0);
        }
    }.cmp);

    var recently_completed = std.ArrayListUnmanaged(CompletedTask){};
    defer recently_completed.deinit(allocator);

    const show_count = @min(depth, completed_tasks_raw.len);
    for (completed_tasks_raw[0..show_count]) |task| {
        try recently_completed.append(allocator, .{
            .id = &task.id,
            .title = task.title,
            .completed_at = task.completed_at orelse 0,
        });
    }

    // Counts
    const counts = try store.getTaskCounts();

    // Session notes from git_sync if available
    var session_notes: ?[]const u8 = null;
    if (context.git_sync) |gs| {
        if (try gs.parseSessionState()) |parsed_state| {
            var mutable_state = parsed_state;
            defer mutable_state.deinit(allocator);
            if (mutable_state.notes) |notes| {
                session_notes = try allocator.dupe(u8, notes);
            }
        }
    }
    defer if (session_notes) |n| allocator.free(n);

    const response = Response{
        .session_id = store.session_id,
        .current_task = current_task,
        .ready_tasks = ready_tasks.items,
        .recently_completed = recently_completed.items,
        .counts = .{
            .pending = counts.pending,
            .in_progress = counts.in_progress,
            .completed = counts.completed,
            .blocked = counts.blocked,
        },
        .notes = session_notes,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
