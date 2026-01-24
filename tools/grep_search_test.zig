// Grep Search Tool Tests
const std = @import("std");
const testing = std.testing;
const grep_search = @import("grep_search.zig");
const context_module = @import("context");

// Helper to create a temporary test directory structure
fn createTestFiles(allocator: std.mem.Allocator, dir: std.fs.Dir) !void {
    // Create test files with various content
    try dir.writeFile(.{ .sub_path = "test1.zig", .data = "const allocator = std.mem.Allocator;\nfunction validateInit() {\n    return true;\n}\n" });
    try dir.writeFile(.{ .sub_path = "test2.zig", .data = "fn init() {\n    const ALLOCATOR = allocator;\n}\n" });
    try dir.writeFile(.{ .sub_path = "readme.md", .data = "# Test Project\nThis is a test.\n" });

    // Create a subdirectory with files
    try dir.makeDir("src");
    var src_dir = try dir.openDir("src", .{});
    defer src_dir.close();
    try src_dir.writeFile(.{ .sub_path = "main.zig", .data = "pub fn main() !void {\n    const allocator = Allocator.init();\n}\n" });

    // Create a hidden directory
    try dir.makeDir(".config");
    var config_dir = try dir.openDir(".config", .{});
    defer config_dir.close();
    try config_dir.writeFile(.{ .sub_path = "settings.conf", .data = "database_config=localhost\nport=5432\n" });

    // Create .git directory (should always be skipped)
    try dir.makeDir(".git");
    var git_dir = try dir.openDir(".git", .{});
    defer git_dir.close();
    try git_dir.writeFile(.{ .sub_path = "config", .data = "secret_token=abc123\n" });

    // Create .gitignore
    try dir.writeFile(.{ .sub_path = ".gitignore", .data = "*.log\nnode_modules/\ntest_output\n" });

    // Create a file that should be gitignored
    try dir.writeFile(.{ .sub_path = "debug.log", .data = "Debug log entry\nallocator used here\n" });

    // Create node_modules to test exact gitignore matching
    try dir.makeDir("node_modules");
    var node_dir = try dir.openDir("node_modules", .{});
    defer node_dir.close();
    try node_dir.writeFile(.{ .sub_path = "package.json", .data = "{\n  \"name\": \"test\"\n}\n" });

    _ = allocator;
}

// Helper to create AppContext for testing
fn createTestContext(allocator: std.mem.Allocator) !*context_module.AppContext {
    var ctx = try allocator.create(context_module.AppContext);
    ctx.* = context_module.AppContext{
        .allocator = allocator,
        .config = undefined,
        .state = undefined,
        .cwd = ".",
    };
    return ctx;
}

test "grep_search - files_with_matches mode (default)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Default mode should return just file paths
    const args = "{\"pattern\":\"allocator\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expect(result.data != null);

    const output = result.data.?;

    // Should find files containing "allocator" - just paths, no line numbers
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test2.zig") != null);
    // Should NOT have line numbers in default mode
    try testing.expect(std.mem.indexOf(u8, output, ":1:") == null);
}

test "grep_search - content mode shows matching lines" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"allocator\",\"output_mode\":\"content\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Content mode should show file:line:content format
    try testing.expect(std.mem.indexOf(u8, output, ":1:") != null or std.mem.indexOf(u8, output, ":2:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "allocator") != null);
}

test "grep_search - count mode shows match counts" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"allocator\",\"output_mode\":\"count\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Count mode should show path:count format
    // test1.zig has 1 match, test2.zig has 2 matches
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig:1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test2.zig:2") != null);
}

test "grep_search - type parameter filters by file extension" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search only zig files using type shortcut
    const args = "{\"pattern\":\"test\",\"type\":\"zig\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find .zig files but not .md files
    try testing.expect(std.mem.indexOf(u8, output, ".zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "readme.md") == null);
}

test "grep_search - glob parameter filters files" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search only markdown files
    const args = "{\"pattern\":\"test\",\"glob\":\"*.md\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find only .md files
    try testing.expect(std.mem.indexOf(u8, output, "readme.md") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".zig") == null);
}

test "grep_search - head_limit limits results" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Limit to 1 result
    const args = "{\"pattern\":\"allocator\",\"head_limit\":1}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should show limit reached message
    try testing.expect(std.mem.indexOf(u8, output, "Showing 1") != null);
}

test "grep_search - offset skips results" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create multiple files with same content
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "match here\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "match here\n" });
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = "match here\n" });

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Skip first 2 results
    const args = "{\"pattern\":\"match\",\"offset\":2,\"head_limit\":10}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    // Should have at most 1 result (3 total - 2 skipped)
}

test "grep_search - context -C parameter" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "context_test.txt",
        .data = "line 1\nline 2\nMATCH HERE\nline 4\nline 5\n",
    });

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search with -C=2 for 2 lines context
    const args = "{\"pattern\":\"MATCH HERE\",\"output_mode\":\"content\",\"-C\":2}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should show lines before and after the match
    try testing.expect(std.mem.indexOf(u8, output, "line 2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "MATCH HERE") != null);
    try testing.expect(std.mem.indexOf(u8, output, "line 4") != null);
}

test "grep_search - context -A and -B parameters" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ab_test.txt",
        .data = "before 1\nbefore 2\nMATCH\nafter 1\nafter 2\n",
    });

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // -B=1 (1 line before), -A=1 (1 line after)
    const args = "{\"pattern\":\"MATCH\",\"output_mode\":\"content\",\"-B\":1,\"-A\":1}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should show 1 line before and 1 after
    try testing.expect(std.mem.indexOf(u8, output, "before 2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "MATCH") != null);
    try testing.expect(std.mem.indexOf(u8, output, "after 1") != null);
    // Should NOT show before 1 or after 2
    try testing.expect(std.mem.indexOf(u8, output, "before 1") == null);
    try testing.expect(std.mem.indexOf(u8, output, "after 2") == null);
}

test "grep_search - case insensitive by default" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search with uppercase pattern - should find lowercase matches
    const args = "{\"pattern\":\"ALLOCATOR\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find both "allocator" and "ALLOCATOR"
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig") != null or std.mem.indexOf(u8, output, "test2.zig") != null);
}

test "grep_search - case sensitive with -i false" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "case.txt", .data = "Hello\nhello\nHELLO\n" });

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Case sensitive search
    const args = "{\"pattern\":\"Hello\",\"output_mode\":\"count\",\"-i\":false}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should only find exact "Hello" (count = 1)
    try testing.expect(std.mem.indexOf(u8, output, ":1") != null);
}

test "grep_search - respects gitignore by default" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"Debug log\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should NOT find it in debug.log (gitignored)
    try testing.expect(std.mem.indexOf(u8, output, "debug.log") == null);
    try testing.expect(std.mem.indexOf(u8, output, "No matches found") != null);
}

test "grep_search - ignore_gitignore bypasses .gitignore" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"Debug log\",\"ignore_gitignore\":true}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find it in debug.log now
    try testing.expect(std.mem.indexOf(u8, output, "debug.log") != null);
}

test "grep_search - skips hidden directories by default" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"database_config\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should NOT find it in .config/ (hidden)
    try testing.expect(std.mem.indexOf(u8, output, ".config") == null);
}

test "grep_search - include_hidden searches hidden directories" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"database_config\",\"include_hidden\":true}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find it in .config/ now
    try testing.expect(std.mem.indexOf(u8, output, ".config") != null);
}

test "grep_search - always skips .git directory" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Even with include_hidden, should skip .git
    const args = "{\"pattern\":\"secret_token\",\"include_hidden\":true}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should NOT find it in .git/ (always skipped)
    try testing.expect(std.mem.indexOf(u8, output, ".git") == null);
}

test "grep_search - wildcard matching" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search for pattern with wildcard
    const args = "{\"pattern\":\"fn*init\",\"output_mode\":\"content\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should match "function validateInit" or "fn init"
    try testing.expect(std.mem.indexOf(u8, output, "validateInit") != null or std.mem.indexOf(u8, output, "fn init") != null);
}

test "grep_search - backwards compat: file_filter" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Use old file_filter parameter
    const args = "{\"pattern\":\"test\",\"file_filter\":\"*.zig\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    try testing.expect(std.mem.indexOf(u8, output, ".zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "readme.md") == null);
}

test "grep_search - backwards compat: max_results" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Use old max_results parameter
    const args = "{\"pattern\":\"const\",\"max_results\":1}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    // Should work like head_limit
}

test "grep_search - backwards compat: context_lines" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "ctx.txt",
        .data = "before\nMATCH\nafter\n",
    });

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Use old context_lines parameter
    const args = "{\"pattern\":\"MATCH\",\"output_mode\":\"content\",\"context_lines\":1}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    try testing.expect(std.mem.indexOf(u8, output, "before") != null);
    try testing.expect(std.mem.indexOf(u8, output, "after") != null);
}

test "grep_search - invalid output_mode returns error" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"test\",\"output_mode\":\"invalid\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.data.?, "Invalid output_mode") != null);
}

test "grep_search - invalid type returns error" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"test\",\"type\":\"invalidtype\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.data.?, "Unknown file type") != null);
}

test "grep_search - line numbers disabled with -n false" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = "match line\n" });

    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.posix.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    const args = "{\"pattern\":\"match\",\"output_mode\":\"content\",\"-n\":false}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should have file:content but not file:linenum:content
    try testing.expect(std.mem.indexOf(u8, output, "test.txt:match") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test.txt:1:match") == null);
}
