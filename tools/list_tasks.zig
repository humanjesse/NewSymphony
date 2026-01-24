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
                .description = try allocator.dupe(u8, "List tasks with optional filters and sorting. Returns task details including blockers, timestamps, and labels."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "status": {
                    \\      "oneOf": [
                    \\        {"type": "string", "enum": ["pending", "in_progress", "completed", "blocked", "cancelled"]},
                    \\        {"type": "array", "items": {"type": "string", "enum": ["pending", "in_progress", "completed", "blocked", "cancelled"]}}
                    \\      ],
                    \\      "description": "Filter by status - single value or array of values"
                    \\    },
                    \\    "priority": {
                    \\      "type": "integer",
                    \\      "description": "Filter by priority (0-4, where 0=critical)"
                    \\    },
                    \\    "type": {
                    \\      "oneOf": [
                    \\        {"type": "string", "enum": ["task", "bug", "feature", "research", "molecule"]},
                    \\        {"type": "array", "items": {"type": "string", "enum": ["task", "bug", "feature", "research", "molecule"]}}
                    \\      ],
                    \\      "description": "Filter by task type - single value or array of values"
                    \\    },
                    \\    "parent": {
                    \\      "type": "string",
                    \\      "description": "Filter by parent task ID (8-char hex)"
                    \\    },
                    \\    "label": {
                    \\      "type": "string",
                    \\      "description": "Filter by label"
                    \\    },
                    \\    "ready_only": {
                    \\      "type": "boolean",
                    \\      "description": "Only show ready-to-work tasks: pending status, no active blockers, excludes molecules (container tasks)"
                    \\    },
                    \\    "sort_by": {
                    \\      "type": "string",
                    \\      "enum": ["priority", "created_at", "updated_at"],
                    \\      "description": "Sort results by field (default: priority)"
                    \\    },
                    \\    "sort_order": {
                    \\      "type": "string",
                    \\      "enum": ["asc", "desc"],
                    \\      "description": "Sort order: asc or desc (default: asc for priority, desc for timestamps)"
                    \\    },
                    \\    "limit": {
                    \\      "type": "integer",
                    \\      "description": "Maximum number of tasks to return (default: 50, max: 200)"
                    \\    },
                    \\    "offset": {
                    \\      "type": "integer",
                    \\      "description": "Number of tasks to skip for pagination (default: 0)"
                    \\    },
                    \\    "include_description": {
                    \\      "type": "boolean",
                    \\      "description": "Include task description preview in output (default: false)"
                    \\    },
                    \\    "search": {
                    \\      "type": "string",
                    \\      "description": "Case-insensitive text search in task title and description"
                    \\    },
                    \\    "include_blocks": {
                    \\      "type": "boolean",
                    \\      "description": "Include blocks_ids showing tasks that will be unblocked when this task completes (default: false)"
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

/// Sort field options
const SortBy = enum {
    priority,
    created_at,
    updated_at,
};

/// Sort order options
const SortOrder = enum {
    asc,
    desc,
};

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Parse arguments - use std.json.Value for flexible status parsing
    var filter = TaskFilter{};
    var sort_by: SortBy = .priority;
    var sort_order: ?SortOrder = null; // null means use default for sort_by
    var limit: usize = 50;
    var offset: usize = 0;
    var include_description: bool = false;
    var include_blocks: bool = false;
    var status_filter: ?[]TaskStatus = null; // For multi-status filtering
    defer if (status_filter) |sf| allocator.free(sf);
    var type_filter: ?[]TaskType = null; // For multi-type filtering
    defer if (type_filter) |tf| allocator.free(tf);

    if (arguments.len > 2) { // Not empty "{}"
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch {
            return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return ToolResult.err(allocator, .parse_error, "Arguments must be an object", start_time);
        }

        const obj = root.object;

        // Handle status - can be string or array
        if (obj.get("status")) |status_val| {
            switch (status_val) {
                .string => |s| {
                    if (TaskStatus.fromString(s)) |st| {
                        filter.status = st;
                    }
                },
                .array => |arr| {
                    var statuses = std.ArrayListUnmanaged(TaskStatus){};
                    for (arr.items) |item| {
                        if (item == .string) {
                            if (TaskStatus.fromString(item.string)) |st| {
                                try statuses.append(allocator, st);
                            }
                        }
                    }
                    if (statuses.items.len > 0) {
                        status_filter = try statuses.toOwnedSlice(allocator);
                    } else {
                        statuses.deinit(allocator);
                    }
                },
                else => {},
            }
        }

        if (obj.get("priority")) |p| {
            if (p == .integer) {
                filter.priority = TaskPriority.fromInt(@intCast(@min(4, @max(0, p.integer))));
            }
        }
        // Handle type - can be string or array
        if (obj.get("type")) |type_val| {
            switch (type_val) {
                .string => |t| {
                    filter.task_type = TaskType.fromString(t);
                },
                .array => |arr| {
                    var types = std.ArrayListUnmanaged(TaskType){};
                    for (arr.items) |item| {
                        if (item == .string) {
                            if (TaskType.fromString(item.string)) |tt| {
                                try types.append(allocator, tt);
                            }
                        }
                    }
                    if (types.items.len > 0) {
                        type_filter = try types.toOwnedSlice(allocator);
                    } else {
                        types.deinit(allocator);
                    }
                },
                else => {},
            }
        }
        if (obj.get("parent")) |parent_val| {
            if (parent_val == .string) {
                const parent_str = parent_val.string;
                if (parent_str.len == 8) {
                    filter.parent_id = TaskStore.parseId(parent_str) catch null;
                }
            }
        }
        if (obj.get("label")) |l| {
            if (l == .string) {
                filter.label = l.string;
            }
        }
        if (obj.get("ready_only")) |r| {
            if (r == .bool) {
                filter.ready_only = r.bool;
            }
        }
        if (obj.get("sort_by")) |sb| {
            if (sb == .string) {
                if (std.mem.eql(u8, sb.string, "created_at")) {
                    sort_by = .created_at;
                } else if (std.mem.eql(u8, sb.string, "updated_at")) {
                    sort_by = .updated_at;
                } else {
                    sort_by = .priority;
                }
            }
        }
        if (obj.get("sort_order")) |so| {
            if (so == .string) {
                if (std.mem.eql(u8, so.string, "desc")) {
                    sort_order = .desc;
                } else if (std.mem.eql(u8, so.string, "asc")) {
                    sort_order = .asc;
                }
            }
        }
        if (obj.get("limit")) |l| {
            if (l == .integer) {
                limit = @intCast(@min(200, @max(1, l.integer)));
            }
        }
        if (obj.get("offset")) |o| {
            if (o == .integer) {
                offset = @intCast(@max(0, o.integer));
            }
        }
        if (obj.get("include_description")) |id| {
            if (id == .bool) {
                include_description = id.bool;
            }
        }
        if (obj.get("search")) |s| {
            if (s == .string and s.string.len > 0) {
                filter.search = s.string;
            }
        }
        if (obj.get("include_blocks")) |ib| {
            if (ib == .bool) {
                include_blocks = ib.bool;
            }
        }
    }

    // Apply default sort order based on sort_by
    const effective_sort_order = sort_order orelse switch (sort_by) {
        .priority => SortOrder.asc, // Lower priority number = higher priority
        .created_at, .updated_at => SortOrder.desc, // Newest first
    };

    // Get tasks using arena allocator (auto-freed when tool returns)
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    var all_tasks = store.listTasksWithAllocator(filter, task_alloc) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to list tasks", start_time);
    };
    // No defer needed - arena handles cleanup

    // Apply multi-status filter if specified (post-filter since TaskFilter only supports single status)
    if (status_filter) |statuses| {
        var filtered = std.ArrayListUnmanaged(task_store.Task){};
        for (all_tasks) |task| {
            for (statuses) |st| {
                if (task.status == st) {
                    try filtered.append(task_alloc, task);
                    break;
                }
            }
        }
        all_tasks = try filtered.toOwnedSlice(task_alloc);
    }

    // Apply multi-type filter if specified
    if (type_filter) |types| {
        var filtered = std.ArrayListUnmanaged(task_store.Task){};
        for (all_tasks) |task| {
            for (types) |tt| {
                if (task.task_type == tt) {
                    try filtered.append(task_alloc, task);
                    break;
                }
            }
        }
        all_tasks = try filtered.toOwnedSlice(task_alloc);
    }

    // Track total before pagination for has_more calculation
    const total_before_pagination = all_tasks.len;

    // Response structs for JSON serialization
    const BlockerInfoJson = struct {
        id: []const u8,
        title: []const u8,
        completed: bool,
    };

    const TaskInfo = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        priority: u8,
        @"type": []const u8,
        // Hierarchy depth: 0=root (no parent), 1=child of root, etc.
        hierarchy_depth: usize,
        // Computed convenience fields
        is_actionable: bool, // true if: pending, no active blockers, not a molecule
        has_blockers: bool, // true if blocked_by_count > 0
        // Renamed from blocked_by for clarity - count of ACTIVE (incomplete) blockers
        blocked_by_count: usize,
        // All blockers with completion status - for full dependency visibility
        blocked_by_ids: []const BlockerInfoJson = &.{},
        // Tasks that will be unblocked when this task completes (opt-in via include_blocks)
        blocks_ids: []const BlockerInfoJson = &.{},
        blocked_reason: ?[]const u8 = null,
        // Timestamps for identifying stale tasks
        created_at: i64,
        updated_at: i64,
        // Labels for categorization
        labels: []const []const u8 = &.{},
        // Comments preview - helps identify tasks with recent activity
        comments_count: usize = 0,
        last_comment_preview: ?[]const u8 = null,
        // Description preview (optional, enabled via include_description)
        description_preview: ?[]const u8 = null,
        // Parent context (for subtasks)
        parent_id: ?[]const u8 = null,
        parent_title: ?[]const u8 = null,
        // For molecules only - full status breakdown
        children_count: ?usize = null,
        ready_count: ?usize = null,
        completed_count: ?usize = null,
        in_progress_count: ?usize = null,
        blocked_count: ?usize = null,
        pending_count: ?usize = null,
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
        has_more: bool, // Indicates if there are more tasks beyond limit
        summary: Summary,
    };

    // Sort tasks before building response
    const SortContext = struct {
        sort_by: SortBy,
        sort_order: SortOrder,

        pub fn lessThan(ctx: @This(), a: task_store.Task, b: task_store.Task) bool {
            const cmp = switch (ctx.sort_by) {
                .priority => @as(i64, a.priority.toInt()) - @as(i64, b.priority.toInt()),
                .created_at => a.created_at - b.created_at,
                .updated_at => a.updated_at - b.updated_at,
            };

            return switch (ctx.sort_order) {
                .asc => cmp < 0,
                .desc => cmp > 0,
            };
        }
    };

    std.mem.sort(task_store.Task, all_tasks, SortContext{
        .sort_by = sort_by,
        .sort_order = effective_sort_order,
    }, SortContext.lessThan);

    // Apply pagination after sorting
    const paginated_start = @min(offset, all_tasks.len);
    const paginated_end = @min(offset + limit, all_tasks.len);
    const tasks = all_tasks[paginated_start..paginated_end];
    const has_more = paginated_end < all_tasks.len;

    // Build task info array
    var task_infos = std.ArrayListUnmanaged(TaskInfo){};
    defer task_infos.deinit(allocator);

    // We need to store the id copies and parent_id copies
    var id_bufs = try allocator.alloc([8]u8, tasks.len);
    defer allocator.free(id_bufs);

    var parent_id_bufs = try allocator.alloc([8]u8, tasks.len);
    defer allocator.free(parent_id_bufs);

    // Storage for blocker info arrays and their ID buffers
    var all_blocker_infos = std.ArrayListUnmanaged([]BlockerInfoJson){};
    defer {
        for (all_blocker_infos.items) |infos| {
            allocator.free(infos);
        }
        all_blocker_infos.deinit(allocator);
    }

    var all_blocker_id_bufs = std.ArrayListUnmanaged([][8]u8){};
    defer {
        for (all_blocker_id_bufs.items) |bufs| {
            allocator.free(bufs);
        }
        all_blocker_id_bufs.deinit(allocator);
    }

    // Storage for blocks_ids (tasks this task blocks) - only used when include_blocks=true
    var all_blocks_infos = std.ArrayListUnmanaged([]BlockerInfoJson){};
    defer {
        for (all_blocks_infos.items) |infos| {
            allocator.free(infos);
        }
        all_blocks_infos.deinit(allocator);
    }

    var all_blocks_id_bufs = std.ArrayListUnmanaged([][8]u8){};
    defer {
        for (all_blocks_id_bufs.items) |bufs| {
            allocator.free(bufs);
        }
        all_blocks_id_bufs.deinit(allocator);
    }

    // Get TaskDB for blocker queries
    const db = store.db;

    for (tasks, 0..) |task, i| {
        @memcpy(&id_bufs[i], &task.id);

        // Compute hierarchy depth by traversing parent chain
        var hierarchy_depth: usize = 0;
        var current_parent = task.parent_id;
        while (current_parent != null) {
            hierarchy_depth += 1;
            if (store.getTaskWithAllocator(current_parent.?, task_alloc) catch null) |parent_task| {
                current_parent = parent_task.parent_id;
            } else {
                break;
            }
        }

        // Get all blockers (active + completed) for this task
        const blockers = db.getAllBlockersWithAllocator(task.id, task_alloc) catch &.{};

        // Build blocker info array
        var blocker_infos = try allocator.alloc(BlockerInfoJson, blockers.len);
        var blocker_id_bufs = try allocator.alloc([8]u8, blockers.len);

        for (blockers, 0..) |blocker, j| {
            @memcpy(&blocker_id_bufs[j], &blocker.id);
            blocker_infos[j] = .{
                .id = &blocker_id_bufs[j],
                .title = blocker.title,
                .completed = blocker.completed,
            };
        }

        try all_blocker_infos.append(allocator, blocker_infos);
        try all_blocker_id_bufs.append(allocator, blocker_id_bufs);

        // Get all tasks this task blocks (only when include_blocks is true)
        var blocks_infos: []BlockerInfoJson = &.{};
        if (include_blocks) {
            const blocking = db.getAllBlockingWithAllocator(task.id, task_alloc) catch &.{};

            // Build blocks info array (same pattern as blocker_infos)
            var blocks_info_arr = try allocator.alloc(BlockerInfoJson, blocking.len);
            var blocks_id_bufs_arr = try allocator.alloc([8]u8, blocking.len);

            for (blocking, 0..) |blocked, j| {
                @memcpy(&blocks_id_bufs_arr[j], &blocked.id);
                blocks_info_arr[j] = .{
                    .id = &blocks_id_bufs_arr[j],
                    .title = blocked.title,
                    .completed = blocked.completed,
                };
            }

            try all_blocks_infos.append(allocator, blocks_info_arr);
            try all_blocks_id_bufs.append(allocator, blocks_id_bufs_arr);
            blocks_infos = blocks_info_arr;
        }

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

        // Get parent info if task has a parent
        var parent_id_ptr: ?[]const u8 = null;
        var parent_title: ?[]const u8 = null;
        if (task.parent_id) |pid| {
            @memcpy(&parent_id_bufs[i], &pid);
            parent_id_ptr = &parent_id_bufs[i];
            if (store.getTaskWithAllocator(pid, task_alloc) catch null) |parent| {
                parent_title = parent.title;
            }
        }

        // For molecules, get full child status breakdown
        var children_count: ?usize = null;
        var ready_count: ?usize = null;
        var completed_count: ?usize = null;
        var in_progress_count: ?usize = null;
        var blocked_count: ?usize = null;
        var pending_count: ?usize = null;
        if (task.task_type == .molecule) {
            const children = store.getChildrenWithAllocator(task.id, task_alloc) catch &.{};
            children_count = children.len;
            var ready: usize = 0;
            var completed: usize = 0;
            var in_progress: usize = 0;
            var blocked: usize = 0;
            var pending: usize = 0;
            for (children) |child| {
                switch (child.status) {
                    .completed => completed += 1,
                    .in_progress => in_progress += 1,
                    .blocked => blocked += 1,
                    .pending => {
                        pending += 1;
                        if (child.blocked_by_count == 0) {
                            ready += 1;
                        }
                    },
                    .cancelled => {},
                }
            }
            ready_count = ready;
            completed_count = completed;
            in_progress_count = in_progress;
            blocked_count = blocked;
            pending_count = pending;
        }

        // Comments preview - show count and last comment
        const comments_count = task.comments.len;
        var last_comment_preview: ?[]const u8 = null;
        if (task.comments.len > 0) {
            const last_comment = task.comments[task.comments.len - 1].content;
            // Truncate to ~100 chars for preview
            const max_preview_len: usize = 100;
            if (last_comment.len <= max_preview_len) {
                last_comment_preview = last_comment;
            } else {
                // Find a good break point (space) near the limit
                var break_pos = max_preview_len;
                while (break_pos > max_preview_len - 20 and break_pos > 0) : (break_pos -= 1) {
                    if (last_comment[break_pos] == ' ') break;
                }
                if (break_pos == 0) break_pos = max_preview_len;
                last_comment_preview = last_comment[0..break_pos];
            }
        }

        // Description preview (optional)
        var description_preview: ?[]const u8 = null;
        if (include_description) {
            if (task.description) |desc| {
                const max_desc_len: usize = 200;
                if (desc.len <= max_desc_len) {
                    description_preview = desc;
                } else {
                    // Find a good break point (space) near the limit
                    var break_pos = max_desc_len;
                    while (break_pos > max_desc_len - 30 and break_pos > 0) : (break_pos -= 1) {
                        if (desc[break_pos] == ' ') break;
                    }
                    if (break_pos == 0) break_pos = max_desc_len;
                    description_preview = desc[0..break_pos];
                }
            }
        }

        // Compute convenience fields
        const has_blockers = task.blocked_by_count > 0;
        const is_actionable = task.status == .pending and !has_blockers and task.task_type != .molecule;

        try task_infos.append(allocator, .{
            .id = &id_bufs[i],
            .title = task.title,
            .status = task.status.toString(),
            .priority = task.priority.toInt(),
            .@"type" = task.task_type.toString(),
            .hierarchy_depth = hierarchy_depth,
            .is_actionable = is_actionable,
            .has_blockers = has_blockers,
            .blocked_by_count = task.blocked_by_count,
            .blocked_by_ids = blocker_infos,
            .blocks_ids = blocks_infos,
            .blocked_reason = blocked_reason,
            .created_at = task.created_at,
            .updated_at = task.updated_at,
            .labels = task.labels,
            .comments_count = comments_count,
            .last_comment_preview = last_comment_preview,
            .description_preview = description_preview,
            .parent_id = parent_id_ptr,
            .parent_title = parent_title,
            .children_count = children_count,
            .ready_count = ready_count,
            .completed_count = completed_count,
            .in_progress_count = in_progress_count,
            .blocked_count = blocked_count,
            .pending_count = pending_count,
        });
    }

    const counts = try store.getTaskCounts();

    const response = Response{
        .tasks = task_infos.items,
        .total = total_before_pagination,
        .has_more = has_more,
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
