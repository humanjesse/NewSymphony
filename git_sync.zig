// Git Sync - JSONL export/import and SESSION_STATE.md generation
// Enables git-as-memory for cross-session continuity
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = mem.Allocator;
const task_store_module = @import("task_store");
const TaskStore = task_store_module.TaskStore;
const Task = task_store_module.Task;
const TaskId = task_store_module.TaskId;
const TaskStatus = task_store_module.TaskStatus;
const Dependency = task_store_module.Dependency;
const Comment = task_store_module.Comment;
const html_utils = @import("html_utils");

/// Session state summary for cold start
pub const SessionState = struct {
    session_id: ?[]const u8,
    current_task_id: ?TaskId,
    last_completed: ?TaskId,
    ready_count: usize,
    blocked_count: usize,
    active_molecule: ?TaskId,
    notes: ?[]const u8,

    pub fn deinit(self: *SessionState, allocator: Allocator) void {
        if (self.session_id) |sid| allocator.free(sid);
        if (self.notes) |n| allocator.free(n);
    }
};

/// Parsed session context with full task details
pub const SessionContext = struct {
    session_id: ?[]const u8,
    current_task: ?Task,
    ready_tasks: []Task,
    blocked_tasks: []Task,
    last_completed: ?Task,
    notes: ?[]const u8,

    pub fn deinit(self: *SessionContext, allocator: Allocator) void {
        if (self.session_id) |sid| allocator.free(sid);
        if (self.notes) |n| allocator.free(n);
        allocator.free(self.ready_tasks);
        allocator.free(self.blocked_tasks);
    }
};

/// Git sync manager for task persistence
pub const GitSync = struct {
    allocator: Allocator,
    repo_path: []const u8,
    tasks_dir: []const u8, // Full path to .tasks/ directory

    const Self = @This();
    const TASKS_FILE = "tasks.jsonl";
    const DEPS_FILE = "dependencies.jsonl";
    const STATE_FILE = "SESSION_STATE.md";

    /// Initialize GitSync with repo path
    pub fn init(allocator: Allocator, repo_path: []const u8) !Self {
        const tasks_dir = try std.fmt.allocPrint(allocator, "{s}/.tasks", .{repo_path});
        return .{
            .allocator = allocator,
            .repo_path = try allocator.dupe(u8, repo_path),
            .tasks_dir = tasks_dir,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.repo_path);
        self.allocator.free(self.tasks_dir);
    }

    /// Ensure .tasks/ directory exists
    pub fn ensureTasksDir(self: *Self) !void {
        fs.cwd().makeDir(self.tasks_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    /// Export all tasks to tasks.jsonl
    pub fn exportTasks(self: *Self, store: *TaskStore) !void {
        try self.ensureTasksDir();

        const tasks_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.tasks_dir, TASKS_FILE });
        defer self.allocator.free(tasks_path);

        // Build content in memory
        var content = std.ArrayListUnmanaged(u8){};
        defer content.deinit(self.allocator);

        // Iterate all tasks and write as JSONL
        var iter = store.tasks.valueIterator();
        while (iter.next()) |task| {
            // Skip wisps - they're ephemeral
            if (task.task_type == .wisp) continue;

            try self.writeTaskJson(&content, task.*);
            try content.append(self.allocator, '\n');
        }

        // Write to file
        const file = try fs.cwd().createFile(tasks_path, .{});
        defer file.close();
        try file.writeAll(content.items);
    }

    /// Export all dependencies to dependencies.jsonl
    pub fn exportDependencies(self: *Self, store: *TaskStore) !void {
        try self.ensureTasksDir();

        const deps_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.tasks_dir, DEPS_FILE });
        defer self.allocator.free(deps_path);

        // Build content in memory
        var content = std.ArrayListUnmanaged(u8){};
        defer content.deinit(self.allocator);

        for (store.dependencies.items) |dep| {
            try content.writer(self.allocator).print("{{\"src\":\"{s}\",\"dst\":\"{s}\",\"type\":\"{s}\",\"weight\":{d}}}\n", .{
                &dep.src_id,
                &dep.dst_id,
                dep.dep_type.toString(),
                dep.weight,
            });
        }

        // Write to file
        const file = try fs.cwd().createFile(deps_path, .{});
        defer file.close();
        try file.writeAll(content.items);
    }

    /// Write a single task as JSON to a buffer
    fn writeTaskJson(self: *Self, buf: *std.ArrayListUnmanaged(u8), task: Task) !void {
        const writer = buf.writer(self.allocator);

        try writer.writeAll("{");

        // id
        try writer.print("\"id\":\"{s}\"", .{&task.id});

        // title (escaped)
        const escaped_title = try html_utils.escapeJSON(self.allocator, task.title);
        defer self.allocator.free(escaped_title);
        try writer.print(",\"title\":\"{s}\"", .{escaped_title});

        // description (optional)
        if (task.description) |desc| {
            const escaped_desc = try html_utils.escapeJSON(self.allocator, desc);
            defer self.allocator.free(escaped_desc);
            try writer.print(",\"description\":\"{s}\"", .{escaped_desc});
        }

        // status
        try writer.print(",\"status\":\"{s}\"", .{task.status.toString()});

        // priority
        try writer.print(",\"priority\":{d}", .{task.priority.toInt()});

        // type
        try writer.print(",\"type\":\"{s}\"", .{task.task_type.toString()});

        // labels
        try writer.writeAll(",\"labels\":[");
        for (task.labels, 0..) |label, i| {
            if (i > 0) try writer.writeByte(',');
            const escaped_label = try html_utils.escapeJSON(self.allocator, label);
            defer self.allocator.free(escaped_label);
            try writer.print("\"{s}\"", .{escaped_label});
        }
        try writer.writeByte(']');

        // timestamps
        try writer.print(",\"created_at\":{d}", .{task.created_at});
        try writer.print(",\"updated_at\":{d}", .{task.updated_at});
        if (task.completed_at) |completed| {
            try writer.print(",\"completed_at\":{d}", .{completed});
        }

        // parent_id
        if (task.parent_id) |pid| {
            try writer.print(",\"parent_id\":\"{s}\"", .{&pid});
        }

        // comments (Beads audit trail)
        try writer.writeAll(",\"comments\":[");
        for (task.comments, 0..) |comment, i| {
            if (i > 0) try writer.writeByte(',');
            const escaped_agent = try html_utils.escapeJSON(self.allocator, comment.agent);
            defer self.allocator.free(escaped_agent);
            const escaped_content = try html_utils.escapeJSON(self.allocator, comment.content);
            defer self.allocator.free(escaped_content);
            try writer.print("{{\"agent\":\"{s}\",\"content\":\"{s}\",\"timestamp\":{d}}}", .{
                escaped_agent,
                escaped_content,
                comment.timestamp,
            });
        }
        try writer.writeByte(']');

        try writer.writeByte('}');
    }

    /// Import tasks from JSONL files
    pub fn importTasks(self: *Self, store: *TaskStore) !usize {
        var imported: usize = 0;

        // Import tasks
        const tasks_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.tasks_dir, TASKS_FILE });
        defer self.allocator.free(tasks_path);

        if (fs.cwd().openFile(tasks_path, .{})) |file| {
            defer file.close();
            imported += try self.importTasksFromFile(file, store);
        } else |_| {
            // File doesn't exist, that's fine
        }

        // Import dependencies
        const deps_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.tasks_dir, DEPS_FILE });
        defer self.allocator.free(deps_path);

        if (fs.cwd().openFile(deps_path, .{})) |file| {
            defer file.close();
            try self.importDependenciesFromFile(file, store);
        } else |_| {
            // File doesn't exist, that's fine
        }

        return imported;
    }

    /// Import tasks from a JSONL file
    fn importTasksFromFile(self: *Self, file: fs.File, store: *TaskStore) !usize {
        var imported: usize = 0;
        var buf: [16384]u8 = undefined;
        var line_buf = std.ArrayListUnmanaged(u8){};
        defer line_buf.deinit(self.allocator);

        while (true) {
            const bytes_read = file.read(&buf) catch break;
            if (bytes_read == 0) break;

            for (buf[0..bytes_read]) |c| {
                if (c == '\n') {
                    if (line_buf.items.len > 0) {
                        if (try self.parseAndAddTask(line_buf.items, store)) {
                            imported += 1;
                        }
                        line_buf.clearRetainingCapacity();
                    }
                } else {
                    try line_buf.append(self.allocator, c);
                }
            }
        }

        // Handle last line without newline
        if (line_buf.items.len > 0) {
            if (try self.parseAndAddTask(line_buf.items, store)) {
                imported += 1;
            }
        }

        return imported;
    }

    /// Parse a JSON line and add task to store
    fn parseAndAddTask(self: *Self, json_line: []const u8, store: *TaskStore) !bool {
        const CommentJson = struct {
            agent: []const u8,
            content: []const u8,
            timestamp: i64,
        };

        const TaskJson = struct {
            id: []const u8,
            title: []const u8,
            description: ?[]const u8 = null,
            status: []const u8,
            priority: u8,
            type: []const u8,
            labels: ?[]const []const u8 = null,
            created_at: i64,
            updated_at: i64,
            completed_at: ?i64 = null,
            parent_id: ?[]const u8 = null,
            comments: ?[]const CommentJson = null,
        };

        const parsed = std.json.parseFromSlice(TaskJson, self.allocator, json_line, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();

        const data = parsed.value;

        // Parse task ID
        if (data.id.len != 8) return false;
        var id: TaskId = undefined;
        @memcpy(&id, data.id[0..8]);

        // Check for collision
        if (store.tasks.contains(id)) return false;

        // Clone strings
        const title = try self.allocator.dupe(u8, data.title);
        errdefer self.allocator.free(title);

        const description = if (data.description) |desc|
            try self.allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |d| self.allocator.free(d);

        // Clone labels
        const labels: [][]const u8 = if (data.labels) |lbls| blk: {
            const cloned = try self.allocator.alloc([]const u8, lbls.len);
            errdefer self.allocator.free(cloned);
            var i: usize = 0;
            errdefer {
                for (cloned[0..i]) |l| self.allocator.free(l);
            }
            for (lbls) |lbl| {
                cloned[i] = try self.allocator.dupe(u8, lbl);
                i += 1;
            }
            break :blk cloned;
        } else try self.allocator.alloc([]const u8, 0);

        // Clone comments (Beads audit trail)
        const comments: []Comment = if (data.comments) |cmts| blk: {
            const cloned = try self.allocator.alloc(Comment, cmts.len);
            errdefer self.allocator.free(cloned);
            var i: usize = 0;
            errdefer {
                for (cloned[0..i]) |*c| {
                    self.allocator.free(c.agent);
                    self.allocator.free(c.content);
                }
            }
            for (cmts) |cmt| {
                cloned[i] = .{
                    .agent = try self.allocator.dupe(u8, cmt.agent),
                    .content = try self.allocator.dupe(u8, cmt.content),
                    .timestamp = cmt.timestamp,
                };
                i += 1;
            }
            break :blk cloned;
        } else try self.allocator.alloc(Comment, 0);

        // Parse parent_id
        var parent_id: ?TaskId = null;
        if (data.parent_id) |pid_str| {
            if (pid_str.len == 8) {
                var pid: TaskId = undefined;
                @memcpy(&pid, pid_str[0..8]);
                parent_id = pid;
            }
        }

        const task = Task{
            .id = id,
            .title = title,
            .description = description,
            .status = task_store_module.TaskStatus.fromString(data.status) orelse .pending,
            .priority = task_store_module.TaskPriority.fromInt(data.priority),
            .task_type = task_store_module.TaskType.fromString(data.type) orelse .task,
            .labels = labels,
            .created_at = data.created_at,
            .updated_at = data.updated_at,
            .completed_at = data.completed_at,
            .parent_id = parent_id,
            .comments = comments,
            .blocked_by_count = 0, // Will be computed when loading dependencies
        };

        try store.tasks.put(id, task);
        return true;
    }

    /// Import dependencies from file
    fn importDependenciesFromFile(self: *Self, file: fs.File, store: *TaskStore) !void {
        var buf: [4096]u8 = undefined;
        var line_buf = std.ArrayListUnmanaged(u8){};
        defer line_buf.deinit(self.allocator);

        while (true) {
            const bytes_read = file.read(&buf) catch break;
            if (bytes_read == 0) break;

            for (buf[0..bytes_read]) |c| {
                if (c == '\n') {
                    if (line_buf.items.len > 0) {
                        try self.parseAndAddDependency(line_buf.items, store);
                        line_buf.clearRetainingCapacity();
                    }
                } else {
                    try line_buf.append(self.allocator, c);
                }
            }
        }

        // Handle last line
        if (line_buf.items.len > 0) {
            try self.parseAndAddDependency(line_buf.items, store);
        }
    }

    /// Parse and add a dependency
    fn parseAndAddDependency(self: *Self, json_line: []const u8, store: *TaskStore) !void {
        const DepJson = struct {
            src: []const u8,
            dst: []const u8,
            type: []const u8,
            weight: ?f32 = null,
        };

        const parsed = std.json.parseFromSlice(DepJson, self.allocator, json_line, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        const data = parsed.value;

        if (data.src.len != 8 or data.dst.len != 8) return;

        var src_id: TaskId = undefined;
        var dst_id: TaskId = undefined;
        @memcpy(&src_id, data.src[0..8]);
        @memcpy(&dst_id, data.dst[0..8]);

        const dep_type = task_store_module.DependencyType.fromString(data.type) orelse return;

        // Use addDependency to properly update blocked_by_count
        store.addDependency(src_id, dst_id, dep_type) catch {
            // Dependency might already exist or tasks might not exist
        };
    }

    /// Generate SESSION_STATE.md for cold start
    /// Format matches the planned schema for parser compatibility
    pub fn generateSessionState(self: *Self, store: *TaskStore, session_notes: ?[]const u8) ![]const u8 {
        var md = std.ArrayListUnmanaged(u8){};
        errdefer md.deinit(self.allocator);

        const writer = md.writer(self.allocator);

        // Header with session ID
        try writer.writeAll("# Session State\n\n");
        if (store.session_id) |sid| {
            try writer.print("Session ID: {s}\n", .{sid});
        }
        const now = std.time.timestamp();
        try writer.print("Last Updated: {d}\n\n", .{now});

        // Current Task section
        try writer.writeAll("## Current Task\n");
        if (store.current_task_id) |cid| {
            if (store.tasks.get(cid)) |task| {
                try writer.print("ID: {s}\n", .{&task.id});
                try writer.print("Title: {s}\n", .{task.title});
                try writer.print("Status: {s}\n", .{task.status.toString()});
                try writer.print("Priority: {s}\n", .{switch (task.priority) {
                    .critical => "critical",
                    .high => "high",
                    .medium => "medium",
                    .low => "low",
                    .wishlist => "wishlist",
                }});
            } else {
                try writer.writeAll("None\n");
            }
        } else {
            try writer.writeAll("None\n");
        }
        try writer.writeByte('\n');

        // Ready Queue section
        const ready = try store.getReadyTasks();
        defer self.allocator.free(ready);

        try writer.print("## Ready Queue ({d})\n", .{ready.len});
        for (ready) |task| {
            const prio_str = switch (task.priority) {
                .critical => "P0",
                .high => "P1",
                .medium => "P2",
                .low => "P3",
                .wishlist => "P4",
            };
            try writer.print("- [{s}] {s}: {s}\n", .{ prio_str, &task.id, task.title });
        }
        try writer.writeByte('\n');

        // Blocked section
        const counts = store.getTaskCounts();
        try writer.print("## Blocked ({d})\n", .{counts.blocked});

        var blocked_iter = store.tasks.valueIterator();
        while (blocked_iter.next()) |task| {
            if (task.status == .blocked) {
                try writer.print("- {s}: {s}", .{ &task.id, task.title });

                // Find what's blocking it
                var blockers = std.ArrayListUnmanaged([]const u8){};
                defer blockers.deinit(self.allocator);

                for (store.dependencies.items) |dep| {
                    if (mem.eql(u8, &dep.dst_id, &task.id) and dep.dep_type.isBlocking()) {
                        try blockers.append(self.allocator, &dep.src_id);
                    }
                }

                if (blockers.items.len > 0) {
                    try writer.writeAll(" (blocked by: ");
                    for (blockers.items, 0..) |blocker_id, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll(blocker_id);
                    }
                    try writer.writeByte(')');
                }
                try writer.writeByte('\n');
            }
        }
        try writer.writeByte('\n');

        // Recently Completed section
        var last_completed: ?*Task = null;
        var last_completed_time: i64 = 0;
        var completed_iter = store.tasks.valueIterator();
        while (completed_iter.next()) |task| {
            if (task.status == .completed) {
                if (task.completed_at) |ct| {
                    if (ct > last_completed_time) {
                        last_completed_time = ct;
                        last_completed = task;
                    }
                }
            }
        }

        try writer.writeAll("## Recently Completed\n");
        if (last_completed) |task| {
            try writer.print("- {s}: {s} ({d})\n", .{ &task.id, task.title, task.completed_at.? });
        } else {
            try writer.writeAll("None\n");
        }
        try writer.writeByte('\n');

        // Session Notes section
        try writer.writeAll("## Session Notes\n");
        if (session_notes) |notes| {
            try writer.writeAll(notes);
            try writer.writeByte('\n');
        } else if (ready.len > 0) {
            try writer.print("{d} tasks ready to work on. ", .{ready.len});
            try writer.print("Highest priority: {s}\n", .{ready[0].title});
        } else if (counts.blocked > 0) {
            try writer.print("All {d} pending tasks are blocked. Review dependencies.\n", .{counts.blocked});
        } else {
            try writer.writeAll("No pending tasks. Create new tasks or review completed work.\n");
        }

        return md.toOwnedSlice(self.allocator);
    }

    /// Generate SESSION_STATE.md with default notes (backward compatibility)
    pub fn generateSessionStateDefault(self: *Self, store: *TaskStore) ![]const u8 {
        return self.generateSessionState(store, null);
    }

    /// Write SESSION_STATE.md to disk
    pub fn writeSessionState(self: *Self, store: *TaskStore) !void {
        try self.writeSessionStateWithNotes(store, null);
    }

    /// Write SESSION_STATE.md to disk with custom notes
    pub fn writeSessionStateWithNotes(self: *Self, store: *TaskStore, session_notes: ?[]const u8) !void {
        try self.ensureTasksDir();

        const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.tasks_dir, STATE_FILE });
        defer self.allocator.free(state_path);

        const content = try self.generateSessionState(store, session_notes);
        defer self.allocator.free(content);

        const file = try fs.cwd().createFile(state_path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Full sync: export tasks, dependencies, and state
    pub fn syncAll(self: *Self, store: *TaskStore) !void {
        try self.exportTasks(store);
        try self.exportDependencies(store);
        try self.writeSessionState(store);
    }

    /// Full sync with custom session notes
    pub fn syncAllWithNotes(self: *Self, store: *TaskStore, session_notes: ?[]const u8) !void {
        try self.exportTasks(store);
        try self.exportDependencies(store);
        try self.writeSessionStateWithNotes(store, session_notes);
    }

    /// Parse SESSION_STATE.md file and extract session info for cold start
    pub fn parseSessionState(self: *Self) !?SessionState {
        const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.tasks_dir, STATE_FILE });
        defer self.allocator.free(state_path);

        const file = fs.cwd().openFile(state_path, .{}) catch return null;
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return null;

        // Read entire file
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var state = SessionState{
            .session_id = null,
            .current_task_id = null,
            .last_completed = null,
            .ready_count = 0,
            .blocked_count = 0,
            .active_molecule = null,
            .notes = null,
        };

        // Parse line by line
        var lines = mem.splitScalar(u8, content, '\n');
        var in_current_task = false;
        var in_notes = false;
        var notes_buf = std.ArrayListUnmanaged(u8){};
        defer notes_buf.deinit(self.allocator);

        while (lines.next()) |line| {
            const trimmed = mem.trim(u8, line, " \t\r");

            // Check section headers
            if (mem.startsWith(u8, trimmed, "## Current Task")) {
                in_current_task = true;
                in_notes = false;
                continue;
            } else if (mem.startsWith(u8, trimmed, "## Ready Queue")) {
                in_current_task = false;
                in_notes = false;
                // Parse count from header: "## Ready Queue (3)"
                if (mem.indexOf(u8, trimmed, "(")) |start| {
                    if (mem.indexOf(u8, trimmed[start..], ")")) |end| {
                        const count_str = trimmed[start + 1 .. start + end];
                        state.ready_count = std.fmt.parseInt(usize, count_str, 10) catch 0;
                    }
                }
                continue;
            } else if (mem.startsWith(u8, trimmed, "## Blocked")) {
                in_current_task = false;
                in_notes = false;
                // Parse count from header
                if (mem.indexOf(u8, trimmed, "(")) |start| {
                    if (mem.indexOf(u8, trimmed[start..], ")")) |end| {
                        const count_str = trimmed[start + 1 .. start + end];
                        state.blocked_count = std.fmt.parseInt(usize, count_str, 10) catch 0;
                    }
                }
                continue;
            } else if (mem.startsWith(u8, trimmed, "## Session Notes")) {
                in_current_task = false;
                in_notes = true;
                continue;
            } else if (mem.startsWith(u8, trimmed, "##")) {
                in_current_task = false;
                in_notes = false;
                continue;
            }

            // Parse session ID
            if (mem.startsWith(u8, trimmed, "Session ID:")) {
                const value = mem.trim(u8, trimmed["Session ID:".len..], " \t");
                if (value.len > 0) {
                    state.session_id = try self.allocator.dupe(u8, value);
                }
                continue;
            }

            // Parse current task ID
            if (in_current_task and mem.startsWith(u8, trimmed, "ID:")) {
                const value = mem.trim(u8, trimmed["ID:".len..], " \t");
                if (value.len == 8) {
                    var id: TaskId = undefined;
                    @memcpy(&id, value[0..8]);
                    state.current_task_id = id;
                }
                continue;
            }

            // Collect notes
            if (in_notes and trimmed.len > 0) {
                if (notes_buf.items.len > 0) {
                    try notes_buf.append(self.allocator, '\n');
                }
                try notes_buf.appendSlice(self.allocator, trimmed);
            }
        }

        // Store notes if any
        if (notes_buf.items.len > 0) {
            state.notes = try notes_buf.toOwnedSlice(self.allocator);
        }

        return state;
    }

    /// Detect if .tasks/ directory exists with state (alias for parseSessionState)
    pub fn detectExistingState(self: *Self) !?SessionState {
        return self.parseSessionState();
    }

    /// Git commit the .tasks/ directory
    pub fn commit(self: *Self, message: []const u8) !void {
        // Stage .tasks/ directory
        var add_argv = [_][]const u8{ "git", "-C", self.repo_path, "add", ".tasks/" };
        var add_child = std.process.Child.init(&add_argv, self.allocator);
        add_child.cwd = null;

        const add_term = try add_child.spawnAndWait();
        switch (add_term) {
            .Exited => |code| {
                if (code != 0) {
                    std.log.warn("git add .tasks/ failed with exit code {d}", .{code});
                    return error.GitAddFailed;
                }
            },
            else => {
                std.log.warn("git add .tasks/ terminated abnormally", .{});
                return error.GitAddFailed;
            },
        }

        // Commit
        var commit_argv = [_][]const u8{ "git", "-C", self.repo_path, "commit", "-m", message };
        var commit_child = std.process.Child.init(&commit_argv, self.allocator);
        commit_child.cwd = null;

        const commit_term = try commit_child.spawnAndWait();
        switch (commit_term) {
            .Exited => |code| {
                // Exit code 1 = nothing to commit (not an error)
                if (code != 0 and code != 1) {
                    std.log.warn("git commit failed with exit code {d}", .{code});
                    return error.GitCommitFailed;
                }
            },
            else => {
                std.log.warn("git commit terminated abnormally", .{});
                return error.GitCommitFailed;
            },
        }
    }

    /// Check for uncommitted code changes (not in .tasks/)
    pub fn hasUncommittedCodeChanges(self: *Self) !bool {
        var status_argv = [_][]const u8{ "git", "-C", self.repo_path, "status", "--porcelain" };
        var child = std.process.Child.init(&status_argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout orelse return false;
        var output_buf: [4096]u8 = undefined;
        const bytes_read = try stdout.read(&output_buf);

        _ = try child.wait();

        if (bytes_read == 0) return false;

        // Check if any changed files are NOT in .tasks/
        var lines = mem.splitScalar(u8, output_buf[0..bytes_read], '\n');
        while (lines.next()) |line| {
            if (line.len < 3) continue;
            const file_path = mem.trim(u8, line[2..], " \t");
            if (!mem.startsWith(u8, file_path, ".tasks/")) {
                return true; // Found a non-.tasks/ change
            }
        }

        return false;
    }
};
