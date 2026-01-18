// Git Worktree - Beads-style separate branch for task sync
// Enables isolated task commits without polluting the main branch
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = mem.Allocator;

/// Git worktree manager for isolated task commits
pub const GitWorktree = struct {
    allocator: Allocator,
    repo_path: []const u8,
    sync_branch: []const u8,
    worktree_path: []const u8, // .git/worktrees/<sync_branch>

    const Self = @This();

    /// Initialize GitWorktree with repo path and sync branch name
    pub fn init(allocator: Allocator, repo_path: []const u8, sync_branch: []const u8) !Self {
        // Worktree path: .git/worktrees/<sync_branch>
        const worktree_path = try std.fmt.allocPrint(
            allocator,
            "{s}/.git/worktrees/{s}",
            .{ repo_path, sync_branch },
        );
        errdefer allocator.free(worktree_path);

        return .{
            .allocator = allocator,
            .repo_path = try allocator.dupe(u8, repo_path),
            .sync_branch = try allocator.dupe(u8, sync_branch),
            .worktree_path = worktree_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.repo_path);
        self.allocator.free(self.sync_branch);
        self.allocator.free(self.worktree_path);
    }

    /// Check if the sync branch exists
    pub fn branchExists(self: *Self) !bool {
        var argv = [_][]const u8{
            "git", "-C", self.repo_path, "rev-parse", "--verify", self.sync_branch,
        };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const term = try child.wait();

        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    /// Create the sync branch as an orphan branch (no history from main)
    pub fn createSyncBranch(self: *Self) !void {
        // Get current branch to return to
        const current_branch = try self.getCurrentBranch();
        defer self.allocator.free(current_branch);

        // Create orphan branch
        var checkout_argv = [_][]const u8{
            "git", "-C", self.repo_path, "checkout", "--orphan", self.sync_branch,
        };
        try self.runGitCommand(&checkout_argv);

        // Reset to empty state
        var reset_argv = [_][]const u8{
            "git", "-C", self.repo_path, "reset", "--hard",
        };
        // Reset might fail if there's nothing, that's ok
        _ = self.runGitCommand(&reset_argv) catch {};

        // Create initial .tasks/ directory
        const tasks_dir = try std.fmt.allocPrint(self.allocator, "{s}/.tasks", .{self.repo_path});
        defer self.allocator.free(tasks_dir);

        fs.cwd().makeDir(tasks_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Create a .gitkeep file so we have something to commit
        const gitkeep_path = try std.fmt.allocPrint(self.allocator, "{s}/.gitkeep", .{tasks_dir});
        defer self.allocator.free(gitkeep_path);

        const gitkeep = fs.cwd().createFile(gitkeep_path, .{}) catch |err| {
            if (err != error.PathAlreadyExists) return err;
            // File exists, that's fine
            return self.finishBranchSetup(current_branch);
        };
        gitkeep.close();

        // Stage and commit
        var add_argv = [_][]const u8{
            "git", "-C", self.repo_path, "add", ".tasks/",
        };
        try self.runGitCommand(&add_argv);

        var commit_argv = [_][]const u8{
            "git", "-C", self.repo_path, "commit", "-m", "beads: initialize task sync branch",
        };
        // Commit might fail if nothing to commit, that's ok
        _ = self.runGitCommand(&commit_argv) catch {};

        // Return to original branch
        try self.finishBranchSetup(current_branch);
    }

    fn finishBranchSetup(self: *Self, original_branch: []const u8) !void {
        var checkout_back_argv = [_][]const u8{
            "git", "-C", self.repo_path, "checkout", original_branch,
        };
        try self.runGitCommand(&checkout_back_argv);
    }

    /// Get current branch name
    fn getCurrentBranch(self: *Self) ![]const u8 {
        var argv = [_][]const u8{
            "git", "-C", self.repo_path, "rev-parse", "--abbrev-ref", "HEAD",
        };

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &argv,
        }) catch return error.GitCommandFailed;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.GitCommandFailed;
        }

        const branch = mem.trim(u8, result.stdout, " \t\r\n");
        return self.allocator.dupe(u8, branch);
    }

    /// Check if worktree exists
    pub fn worktreeExists(self: *Self) bool {
        // Check if the worktree directory exists
        fs.cwd().access(self.worktree_path, .{}) catch return false;
        return true;
    }

    /// Create the worktree
    pub fn createWorktree(self: *Self) !void {
        var argv = [_][]const u8{
            "git",
            "-C",
            self.repo_path,
            "worktree",
            "add",
            self.worktree_path,
            self.sync_branch,
        };
        try self.runGitCommand(&argv);
    }

    /// Ensure sync branch and worktree exist (idempotent setup)
    pub fn ensureSetup(self: *Self) !void {
        // 1. Create sync branch if it doesn't exist
        if (!try self.branchExists()) {
            try self.createSyncBranch();
        }

        // 2. Create worktree if it doesn't exist
        if (!self.worktreeExists()) {
            try self.createWorktree();
        }

        // 3. Ensure .tasks/ exists in worktree
        const tasks_dir = try std.fmt.allocPrint(self.allocator, "{s}/.tasks", .{self.worktree_path});
        defer self.allocator.free(tasks_dir);

        fs.cwd().makeDir(tasks_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    /// Sync .tasks/ files from main repo to worktree
    pub fn syncTasksToWorktree(self: *Self) !void {
        const src_dir = try std.fmt.allocPrint(self.allocator, "{s}/.tasks", .{self.repo_path});
        defer self.allocator.free(src_dir);

        const dst_dir = try std.fmt.allocPrint(self.allocator, "{s}/.tasks", .{self.worktree_path});
        defer self.allocator.free(dst_dir);

        // Ensure destination exists
        fs.cwd().makeDir(dst_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Copy files (tasks.jsonl, dependencies.jsonl, SESSION_STATE.md)
        const files = [_][]const u8{ "tasks.jsonl", "dependencies.jsonl", "SESSION_STATE.md" };

        for (files) |filename| {
            const src_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ src_dir, filename });
            defer self.allocator.free(src_path);

            const dst_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dst_dir, filename });
            defer self.allocator.free(dst_path);

            // Read source file
            const src_file = fs.cwd().openFile(src_path, .{}) catch continue; // Skip if doesn't exist
            defer src_file.close();

            const content = src_file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch continue;
            defer self.allocator.free(content);

            // Write to destination
            const dst_file = fs.cwd().createFile(dst_path, .{}) catch continue;
            defer dst_file.close();

            dst_file.writeAll(content) catch continue;
        }
    }

    /// Commit changes in the worktree
    pub fn commit(self: *Self, message: []const u8) !void {
        // Stage .tasks/ in worktree
        var add_argv = [_][]const u8{
            "git", "-C", self.worktree_path, "add", ".tasks/",
        };
        try self.runGitCommand(&add_argv);

        // Commit in worktree
        var commit_argv = [_][]const u8{
            "git", "-C", self.worktree_path, "commit", "-m", message,
        };

        // Run commit - exit code 1 means nothing to commit (not an error)
        var child = std.process.Child.init(&commit_argv, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const term = try child.wait();

        switch (term) {
            .Exited => |code| {
                // 0 = success, 1 = nothing to commit
                if (code != 0 and code != 1) {
                    return error.GitCommitFailed;
                }
            },
            else => return error.GitCommitFailed,
        }
    }

    /// Push the sync branch to remote
    pub fn push(self: *Self) !void {
        var argv = [_][]const u8{
            "git", "-C", self.worktree_path, "push", "-u", "origin", self.sync_branch,
        };

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &argv,
        }) catch return error.GitPushFailed;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    std.log.warn("git push failed: {s}", .{result.stderr});
                    return error.GitPushFailed;
                }
            },
            else => return error.GitPushFailed,
        }
    }

    /// Run a git command and check for success
    fn runGitCommand(self: *Self, argv: []const []const u8) !void {
        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const term = try child.wait();

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    return error.GitCommandFailed;
                }
            },
            else => return error.GitCommandFailed,
        }
    }
};
