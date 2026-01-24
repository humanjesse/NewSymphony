// Grep Search Tool - Recursively search files with .gitignore awareness
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Output mode enum
const OutputMode = enum {
    files_with_matches,
    content,
    count,
};

/// File type to glob pattern mapping for grep search.
///
/// Design decisions:
/// - Single extension per type (no composites like "*.{ts,tsx}")
/// - Common aliases included (rust/rs, yaml/yml, bash/sh)
/// - Only code-related file types (no binary formats)
///
/// Usage: `grep_search(pattern: "fn main", type: "zig")`
/// Available types: zig, js, ts, tsx, jsx, py, go, rust, rs, md, json,
///                  yaml, yml, toml, c, cpp, h, hpp, java, rb, php,
///                  swift, kt, scala, sql, html, css, scss, xml, sh, bash
const FileTypeExtensions = std.StaticStringMap([]const u8).initComptime(.{
    .{ "zig", "*.zig" },
    .{ "js", "*.js" },
    .{ "ts", "*.ts" },
    .{ "tsx", "*.tsx" },
    .{ "jsx", "*.jsx" },
    .{ "py", "*.py" },
    .{ "go", "*.go" },
    .{ "rust", "*.rs" },
    .{ "rs", "*.rs" },
    .{ "md", "*.md" },
    .{ "json", "*.json" },
    .{ "yaml", "*.yaml" },
    .{ "yml", "*.yml" },
    .{ "toml", "*.toml" },
    .{ "c", "*.c" },
    .{ "cpp", "*.cpp" },
    .{ "h", "*.h" },
    .{ "hpp", "*.hpp" },
    .{ "java", "*.java" },
    .{ "rb", "*.rb" },
    .{ "php", "*.php" },
    .{ "swift", "*.swift" },
    .{ "kt", "*.kt" },
    .{ "scala", "*.scala" },
    .{ "sql", "*.sql" },
    .{ "html", "*.html" },
    .{ "css", "*.css" },
    .{ "scss", "*.scss" },
    .{ "xml", "*.xml" },
    .{ "sh", "*.sh" },
    .{ "bash", "*.sh" },
});

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "grep_search"),
                .description = try allocator.dupe(u8,
                    \\Search file contents for patterns.
                    \\
                    \\OUTPUT MODES (output_mode):
                    \\- "files_with_matches" (default): Just file paths, one per line
                    \\- "content": Shows matching lines with optional context (-A/-B/-C)
                    \\- "count": Shows match counts per file
                    \\
                    \\FILTERING:
                    \\- glob: Pattern like "*.zig" or "**/*.ts"
                    \\- type: Shortcut - "zig", "js", "py", "go", "rust", etc.
                    \\
                    \\PAGINATION:
                    \\- head_limit: Limit results (default: 50 for files, 100 for content)
                    \\- offset: Skip N results for paging
                ),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "pattern": {
                    \\      "type": "string",
                    \\      "description": "Text or regex pattern to search for (supports * wildcards)"
                    \\    },
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "Directory to search in (default: current working directory)"
                    \\    },
                    \\    "glob": {
                    \\      "type": "string",
                    \\      "description": "Glob pattern to filter files (e.g., '*.zig', '**/*.ts')"
                    \\    },
                    \\    "type": {
                    \\      "type": "string",
                    \\      "description": "File type shortcut: zig, js, ts, py, go, rust, md, json, etc."
                    \\    },
                    \\    "output_mode": {
                    \\      "type": "string",
                    \\      "description": "Output format: files_with_matches (default), content, or count"
                    \\    },
                    \\    "head_limit": {
                    \\      "type": "integer",
                    \\      "description": "Limit to first N results (default varies by mode)"
                    \\    },
                    \\    "offset": {
                    \\      "type": "integer",
                    \\      "description": "Skip first N results for pagination"
                    \\    },
                    \\    "-A": {
                    \\      "type": "integer",
                    \\      "description": "Lines after each match (content mode only, max 10)"
                    \\    },
                    \\    "-B": {
                    \\      "type": "integer",
                    \\      "description": "Lines before each match (content mode only, max 10)"
                    \\    },
                    \\    "-C": {
                    \\      "type": "integer",
                    \\      "description": "Lines before AND after each match (overrides -A/-B, max 10)"
                    \\    },
                    \\    "-n": {
                    \\      "type": "boolean",
                    \\      "description": "Show line numbers (default: true for content mode)"
                    \\    },
                    \\    "-i": {
                    \\      "type": "boolean",
                    \\      "description": "Case insensitive search (default: true)"
                    \\    },
                    \\    "include_hidden": {
                    \\      "type": "boolean",
                    \\      "description": "Search hidden directories (default: false, always skips .git)"
                    \\    },
                    \\    "ignore_gitignore": {
                    \\      "type": "boolean",
                    \\      "description": "Search files excluded by .gitignore (default: false)"
                    \\    }
                    \\  },
                    \\  "required": ["pattern"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "grep_search",
            .description = "Search files in project",
            .risk_level = .low,
            .required_scopes = &.{.read_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

const ContextLine = struct {
    line_number: usize,
    content: []const u8,
};

const SearchResult = struct {
    file_path: []const u8,
    line_number: usize,
    line_content: []const u8,
    context_before: []ContextLine,
    context_after: []ContextLine,
};

const FileMatch = struct {
    file_path: []const u8,
    match_count: usize,
};

const SearchContext = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    case_insensitive: bool,
    head_limit: usize,
    offset: usize,
    file_filter: ?[]const u8,
    include_hidden: bool,
    ignore_gitignore: bool,
    context_before: usize,
    context_after: usize,
    show_line_numbers: bool,
    output_mode: OutputMode,
    search_path: ?[]const u8,
    gitignore_patterns: std.ArrayListUnmanaged([]const u8),
    results: std.ArrayListUnmanaged(SearchResult),
    file_matches: std.ArrayListUnmanaged(FileMatch),
    files_searched: usize,
    files_skipped: usize,
    results_collected: usize,
    results_skipped: usize,
    current_path: std.ArrayListUnmanaged(u8),
};

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context;
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        pattern: []const u8,
        path: ?[]const u8 = null,
        glob: ?[]const u8 = null,
        type: ?[]const u8 = null,
        output_mode: ?[]const u8 = null,
        head_limit: ?usize = null,
        offset: ?usize = null,
        @"-A": ?usize = null,
        @"-B": ?usize = null,
        @"-C": ?usize = null,
        @"-n": ?bool = null,
        @"-i": ?bool = null,
        include_hidden: ?bool = null,
        ignore_gitignore: ?bool = null,
        // Backwards compatibility
        file_filter: ?[]const u8 = null,
        max_results: ?usize = null,
        context_lines: ?usize = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Validate pattern
    if (args.pattern.len == 0) {
        return ToolResult.err(allocator, .validation_failed, "Pattern cannot be empty", start_time);
    }

    // Parse output mode
    const output_mode: OutputMode = blk: {
        if (args.output_mode) |mode_str| {
            if (std.mem.eql(u8, mode_str, "content")) break :blk .content;
            if (std.mem.eql(u8, mode_str, "count")) break :blk .count;
            if (std.mem.eql(u8, mode_str, "files_with_matches")) break :blk .files_with_matches;
            return ToolResult.err(allocator, .validation_failed, "Invalid output_mode. Use: files_with_matches, content, or count", start_time);
        }
        break :blk .files_with_matches;
    };

    // Resolve file filter: glob > type > file_filter (backwards compat)
    const file_filter: ?[]const u8 = blk: {
        if (args.glob) |g| break :blk g;
        if (args.type) |t| {
            if (FileTypeExtensions.get(t)) |ext| break :blk ext;
            return ToolResult.err(allocator, .validation_failed, "Unknown file type. Use: zig, js, ts, py, go, rust, md, json, etc.", start_time);
        }
        if (args.file_filter) |f| break :blk f; // backwards compat
        break :blk null;
    };

    // Set mode-specific defaults for head_limit
    const default_head_limit: usize = switch (output_mode) {
        .files_with_matches => 50,
        .content => 100,
        .count => 200,
    };
    const head_limit = if (args.head_limit) |hl|
        @min(hl, 500)
    else if (args.max_results) |mr| // backwards compat
        @min(mr, 500)
    else
        default_head_limit;

    const offset = args.offset orelse 0;
    const include_hidden = args.include_hidden orelse false;
    const ignore_gitignore = args.ignore_gitignore orelse false;

    // Handle context lines: -C overrides -A/-B
    const context_c = if (args.@"-C") |c| @min(c, 10) else if (args.context_lines) |cl| @min(cl, 10) else null;
    const context_before = if (context_c) |c| c else if (args.@"-B") |b| @min(b, 10) else 0;
    const context_after = if (context_c) |c| c else if (args.@"-A") |a| @min(a, 10) else 0;

    // Line numbers default to true for content mode
    const show_line_numbers = args.@"-n" orelse (output_mode == .content);

    // Case insensitive defaults to true
    const case_insensitive = args.@"-i" orelse true;

    // Initialize search context
    var search_ctx = SearchContext{
        .allocator = allocator,
        .pattern = args.pattern,
        .case_insensitive = case_insensitive,
        .head_limit = head_limit,
        .offset = offset,
        .file_filter = file_filter,
        .include_hidden = include_hidden,
        .ignore_gitignore = ignore_gitignore,
        .context_before = context_before,
        .context_after = context_after,
        .show_line_numbers = show_line_numbers,
        .output_mode = output_mode,
        .search_path = args.path,
        .gitignore_patterns = .{},
        .results = .{},
        .file_matches = .{},
        .files_searched = 0,
        .files_skipped = 0,
        .results_collected = 0,
        .results_skipped = 0,
        .current_path = .{},
    };
    defer {
        for (search_ctx.gitignore_patterns.items) |pattern| {
            allocator.free(pattern);
        }
        search_ctx.gitignore_patterns.deinit(allocator);
        for (search_ctx.results.items) |result| {
            allocator.free(result.file_path);
            allocator.free(result.line_content);
            for (result.context_before) |ctx_line| {
                allocator.free(ctx_line.content);
            }
            allocator.free(result.context_before);
            for (result.context_after) |ctx_line| {
                allocator.free(ctx_line.content);
            }
            allocator.free(result.context_after);
        }
        search_ctx.results.deinit(allocator);
        for (search_ctx.file_matches.items) |fm| {
            allocator.free(fm.file_path);
        }
        search_ctx.file_matches.deinit(allocator);
        search_ctx.current_path.deinit(allocator);
    }

    // Always load .gitignore patterns
    loadGitignore(&search_ctx) catch {
        // Continue without gitignore if it fails to load
    };

    // Determine search directory
    const cwd = std.fs.cwd();
    var opened_dir: ?std.fs.Dir = null;
    defer if (opened_dir) |*d| d.close();

    const search_dir: std.fs.Dir = if (args.path) |p| blk: {
        opened_dir = cwd.openDir(p, .{ .iterate = true }) catch {
            return ToolResult.err(allocator, .io_error, "Cannot open search path", start_time);
        };
        break :blk opened_dir.?;
    } else cwd;

    const start_path = args.path orelse ".";
    searchDirectory(&search_ctx, search_dir, start_path) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Search failed: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };

    // Format results
    const formatted = try formatResults(&search_ctx);
    defer allocator.free(formatted);
    return ToolResult.ok(allocator, formatted, start_time, null);
}

fn loadGitignore(ctx: *SearchContext) !void {
    const file = std.fs.cwd().openFile(".gitignore", .{}) catch {
        return; // No .gitignore file, continue without it
    };
    defer file.close();

    const content = try file.readToEndAlloc(ctx.allocator, 1024 * 1024); // 1MB max
    defer ctx.allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Store pattern
        const pattern = try ctx.allocator.dupe(u8, trimmed);
        try ctx.gitignore_patterns.append(ctx.allocator, pattern);
    }
}

fn searchDirectory(ctx: *SearchContext, dir: std.fs.Dir, rel_path: []const u8) !void {
    // Check if we've hit the limit (after offset)
    if (ctx.results_collected >= ctx.head_limit) return;

    var iter_dir = dir.openDir(rel_path, .{ .iterate = true }) catch {
        // Skip directories we can't open
        return;
    };
    defer iter_dir.close();

    var iter = iter_dir.iterate();
    while (try iter.next()) |entry| {
        // Check limit again
        if (ctx.results_collected >= ctx.head_limit) return;

        // Build full path
        const entry_path = if (std.mem.eql(u8, rel_path, "."))
            try ctx.allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ rel_path, entry.name });
        defer ctx.allocator.free(entry_path);

        // Check if ignored (only if respecting gitignore)
        if (!ctx.ignore_gitignore and isIgnored(ctx, entry_path)) {
            ctx.files_skipped += 1;
            continue;
        }

        switch (entry.kind) {
            .directory => {
                // Always skip VCS directories
                const vcs_dirs = [_][]const u8{ ".git", ".hg", ".svn", ".bzr" };
                var should_skip_vcs = false;
                for (vcs_dirs) |vcs| {
                    if (std.mem.eql(u8, entry.name, vcs)) {
                        should_skip_vcs = true;
                        break;
                    }
                }
                if (should_skip_vcs) {
                    ctx.files_skipped += 1;
                    continue;
                }

                // Skip other hidden directories unless include_hidden is true
                if (entry.name[0] == '.' and !ctx.include_hidden) {
                    ctx.files_skipped += 1;
                    continue;
                }

                // Recurse into directory
                try searchDirectory(ctx, dir, entry_path);
            },
            .file => {
                // Check file filter
                if (ctx.file_filter) |filter| {
                    if (!matchesGlob(entry_path, filter)) {
                        ctx.files_skipped += 1;
                        continue;
                    }
                }

                // Search the file content
                try searchFile(ctx, dir, entry_path);
            },
            else => {}, // Skip other types (symlinks, etc.)
        }
    }
}

fn searchFile(ctx: *SearchContext, dir: std.fs.Dir, path: []const u8) !void {
    const file = dir.openFile(path, .{}) catch {
        ctx.files_skipped += 1;
        return; // Skip files we can't open
    };
    defer file.close();

    // Read file content
    const content = file.readToEndAlloc(ctx.allocator, 10 * 1024 * 1024) catch {
        ctx.files_skipped += 1;
        return; // Skip files we can't read or that are too large
    };
    defer ctx.allocator.free(content);

    // Check for binary content
    if (isBinary(content)) {
        ctx.files_skipped += 1;
        return;
    }

    ctx.files_searched += 1;

    // Collect all lines into an array for context access
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(ctx.allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(ctx.allocator, line);
    }

    // Count matches and find first match
    var match_count: usize = 0;
    var first_match_idx: ?usize = null;

    for (lines.items, 0..) |line, idx| {
        if (matchesPattern(ctx, line)) {
            match_count += 1;
            if (first_match_idx == null) first_match_idx = idx;
        }
    }

    // No matches in this file
    if (match_count == 0) return;

    // Handle based on output mode
    switch (ctx.output_mode) {
        .files_with_matches => {
            // Just record the file path
            const total_seen = ctx.file_matches.items.len;
            if (total_seen < ctx.offset) {
                ctx.results_skipped += 1;
            } else if (ctx.results_collected < ctx.head_limit) {
                try ctx.file_matches.append(ctx.allocator, .{
                    .file_path = try ctx.allocator.dupe(u8, path),
                    .match_count = match_count,
                });
                ctx.results_collected += 1;
            }
        },
        .count => {
            // Record file path with count
            const total_seen = ctx.file_matches.items.len;
            if (total_seen < ctx.offset) {
                ctx.results_skipped += 1;
            } else if (ctx.results_collected < ctx.head_limit) {
                try ctx.file_matches.append(ctx.allocator, .{
                    .file_path = try ctx.allocator.dupe(u8, path),
                    .match_count = match_count,
                });
                ctx.results_collected += 1;
            }
        },
        .content => {
            // Collect matching lines with context
            for (lines.items, 0..) |line, idx| {
                if (ctx.results_collected >= ctx.head_limit) return;

                if (matchesPattern(ctx, line)) {
                    const total_seen = ctx.results.items.len + ctx.results_skipped;
                    if (total_seen < ctx.offset) {
                        ctx.results_skipped += 1;
                        continue;
                    }

                    const line_num = idx + 1;

                    // Collect context before
                    var cb = std.ArrayListUnmanaged(ContextLine){};
                    errdefer {
                        for (cb.items) |ctx_line| ctx.allocator.free(ctx_line.content);
                        cb.deinit(ctx.allocator);
                    }
                    if (ctx.context_before > 0) {
                        const start = if (idx >= ctx.context_before) idx - ctx.context_before else 0;
                        for (start..idx) |ctx_idx| {
                            try cb.append(ctx.allocator, .{
                                .line_number = ctx_idx + 1,
                                .content = try ctx.allocator.dupe(u8, lines.items[ctx_idx]),
                            });
                        }
                    }

                    // Collect context after
                    var ca = std.ArrayListUnmanaged(ContextLine){};
                    errdefer {
                        for (ca.items) |ctx_line| ctx.allocator.free(ctx_line.content);
                        ca.deinit(ctx.allocator);
                    }
                    if (ctx.context_after > 0) {
                        const end = @min(idx + ctx.context_after + 1, lines.items.len);
                        for ((idx + 1)..end) |ctx_idx| {
                            try ca.append(ctx.allocator, .{
                                .line_number = ctx_idx + 1,
                                .content = try ctx.allocator.dupe(u8, lines.items[ctx_idx]),
                            });
                        }
                    }

                    // Store result
                    const result = SearchResult{
                        .file_path = try ctx.allocator.dupe(u8, path),
                        .line_number = line_num,
                        .line_content = try ctx.allocator.dupe(u8, line),
                        .context_before = try cb.toOwnedSlice(ctx.allocator),
                        .context_after = try ca.toOwnedSlice(ctx.allocator),
                    };
                    try ctx.results.append(ctx.allocator, result);
                    ctx.results_collected += 1;
                }
            }
        },
    }
}

fn matchesPattern(ctx: *SearchContext, line: []const u8) bool {
    // Detect if pattern contains wildcards
    const has_wildcard = std.mem.indexOf(u8, ctx.pattern, "*") != null;

    if (has_wildcard) {
        // Pattern has * wildcards - try matching at each position in line (grep-like substring behavior)
        var i: usize = 0;
        while (i <= line.len) : (i += 1) {
            if (matchesWildcard(line[i..], ctx.pattern, ctx.case_insensitive)) {
                return true;
            }
        }
        return false;
    } else {
        // Simple pattern - do substring search
        if (ctx.case_insensitive) {
            return indexOfIgnoreCase(line, ctx.pattern) != null;
        } else {
            return std.mem.indexOf(u8, line, ctx.pattern) != null;
        }
    }
}


fn matchesWildcard(text: []const u8, pattern: []const u8, case_insensitive: bool) bool {
    // Simple wildcard matching with * support
    var text_idx: usize = 0;
    var pat_idx: usize = 0;

    while (pat_idx < pattern.len and text_idx < text.len) {
        if (pattern[pat_idx] == '*') {
            // Try matching rest of pattern at each position
            pat_idx += 1;
            if (pat_idx == pattern.len) return true; // Trailing * matches everything

            while (text_idx < text.len) {
                if (matchesWildcard(text[text_idx..], pattern[pat_idx..], case_insensitive)) {
                    return true;
                }
                text_idx += 1;
            }
            return false;
        } else {
            const pat_char = if (case_insensitive) std.ascii.toLower(pattern[pat_idx]) else pattern[pat_idx];
            const text_char = if (case_insensitive) std.ascii.toLower(text[text_idx]) else text[text_idx];

            if (pat_char != text_char) return false;

            pat_idx += 1;
            text_idx += 1;
        }
    }

    // Handle remaining pattern
    while (pat_idx < pattern.len and pattern[pat_idx] == '*') {
        pat_idx += 1;
    }

    // For grep-like substring matching, pattern just needs to be fully consumed
    // (trailing text after the match is okay)
    return pat_idx == pattern.len;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(c) != std.ascii.toLower(haystack[i + j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn isIgnored(ctx: *SearchContext, path: []const u8) bool {
    for (ctx.gitignore_patterns.items) |pattern| {
        if (matchesGitignorePattern(path, pattern)) {
            return true;
        }
    }
    return false;
}

fn matchesGitignorePattern(path: []const u8, pattern: []const u8) bool {
    // Handle directory patterns (ending with /)
    if (std.mem.endsWith(u8, pattern, "/")) {
        const dir_pattern = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, path, dir_pattern);
    }

    // Handle recursive directory patterns (**/foo)
    if (std.mem.startsWith(u8, pattern, "**/")) {
        const suffix = pattern[3..];
        return std.mem.endsWith(u8, path, suffix) or std.mem.indexOf(u8, path, suffix) != null;
    }

    // Handle extension patterns (*.ext)
    if (std.mem.startsWith(u8, pattern, "*.")) {
        return std.mem.endsWith(u8, path, pattern[1..]);
    }

    // Exact filename match - check basename to avoid false positives
    // (e.g., pattern "node" shouldn't match "node_modules" or "components")
    if (std.mem.indexOf(u8, pattern, "*") == null and std.mem.indexOf(u8, pattern, "/") == null) {
        const basename = std.fs.path.basename(path);
        return std.mem.eql(u8, basename, pattern);
    }

    // Fallback: pattern contains path separator or other wildcards
    if (std.mem.indexOf(u8, path, pattern) != null) {
        return true;
    }

    return false;
}

fn matchesGlob(path: []const u8, glob: []const u8) bool {
    // Simple glob matching for file filtering

    // Match all files
    if (std.mem.eql(u8, glob, "*")) return true;

    // Extension matching (*.ext)
    if (std.mem.startsWith(u8, glob, "*.")) {
        return std.mem.endsWith(u8, path, glob[1..]);
    }

    // Recursive extension matching (**/*.ext)
    if (std.mem.startsWith(u8, glob, "**/*.")) {
        const ext = glob[4..];
        return std.mem.endsWith(u8, path, ext);
    }

    // Directory prefix matching (dir/**)
    if (std.mem.endsWith(u8, glob, "/**")) {
        const prefix = glob[0 .. glob.len - 3];
        return std.mem.startsWith(u8, path, prefix);
    }

    // Exact match
    return std.mem.eql(u8, path, glob);
}

fn isBinary(content: []const u8) bool {
    // Check first 512 bytes for null bytes
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

fn formatResults(ctx: *SearchContext) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(ctx.allocator);
    const writer = output.writer(ctx.allocator);

    switch (ctx.output_mode) {
        .files_with_matches => {
            // Clean file paths, one per line
            if (ctx.file_matches.items.len == 0) {
                try writer.writeAll("No matches found.\n");
            } else {
                for (ctx.file_matches.items) |fm| {
                    try writer.print("{s}\n", .{fm.file_path});
                }
            }
        },
        .count => {
            // path:count format
            if (ctx.file_matches.items.len == 0) {
                try writer.writeAll("No matches found.\n");
            } else {
                for (ctx.file_matches.items) |fm| {
                    try writer.print("{s}:{d}\n", .{ fm.file_path, fm.match_count });
                }
            }
        },
        .content => {
            // Grep-style output with optional context
            if (ctx.results.items.len == 0) {
                try writer.writeAll("No matches found.\n");
            } else {
                var current_file: ?[]const u8 = null;
                var last_line_shown: usize = 0;

                for (ctx.results.items) |result| {
                    const file_changed = current_file == null or !std.mem.eql(u8, current_file.?, result.file_path);
                    if (file_changed) {
                        current_file = result.file_path;
                        last_line_shown = 0;
                    }

                    // Show context before (with deduplication)
                    for (result.context_before) |ctx_line| {
                        if (ctx_line.line_number > last_line_shown) {
                            // Add separator if there's a gap
                            if (last_line_shown > 0 and ctx_line.line_number > last_line_shown + 1) {
                                try writer.writeAll("--\n");
                            }
                            if (ctx.show_line_numbers) {
                                try writer.print("{s}-{d}-{s}\n", .{ result.file_path, ctx_line.line_number, ctx_line.content });
                            } else {
                                try writer.print("{s}-{s}\n", .{ result.file_path, ctx_line.content });
                            }
                            last_line_shown = ctx_line.line_number;
                        }
                    }

                    // Show the match line
                    if (last_line_shown > 0 and result.line_number > last_line_shown + 1) {
                        try writer.writeAll("--\n");
                    }
                    if (ctx.show_line_numbers) {
                        try writer.print("{s}:{d}:{s}\n", .{ result.file_path, result.line_number, result.line_content });
                    } else {
                        try writer.print("{s}:{s}\n", .{ result.file_path, result.line_content });
                    }
                    last_line_shown = result.line_number;

                    // Show context after
                    for (result.context_after) |ctx_line| {
                        if (ctx_line.line_number > last_line_shown) {
                            if (ctx.show_line_numbers) {
                                try writer.print("{s}-{d}-{s}\n", .{ result.file_path, ctx_line.line_number, ctx_line.content });
                            } else {
                                try writer.print("{s}-{s}\n", .{ result.file_path, ctx_line.content });
                            }
                            last_line_shown = ctx_line.line_number;
                        }
                    }
                }
            }
        },
    }

    // Add limit warning if needed
    if (ctx.results_collected >= ctx.head_limit) {
        try writer.print("\n[Showing {d} of {d}+ results. Use offset={d} to see more.]\n", .{
            ctx.head_limit,
            ctx.head_limit + ctx.results_skipped,
            ctx.head_limit + ctx.offset,
        });
    }

    return try output.toOwnedSlice(ctx.allocator);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct {
        pattern: []const u8,
        path: ?[]const u8 = null,
        glob: ?[]const u8 = null,
        type: ?[]const u8 = null,
        output_mode: ?[]const u8 = null,
        head_limit: ?usize = null,
        offset: ?usize = null,
        @"-A": ?usize = null,
        @"-B": ?usize = null,
        @"-C": ?usize = null,
        @"-n": ?bool = null,
        @"-i": ?bool = null,
        include_hidden: ?bool = null,
        ignore_gitignore: ?bool = null,
        // Backwards compatibility
        file_filter: ?[]const u8 = null,
        max_results: ?usize = null,
        context_lines: ?usize = null,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();
    const args = parsed.value;

    // Block empty pattern
    if (args.pattern.len == 0) return false;

    // Validate output_mode if provided
    if (args.output_mode) |mode| {
        const valid_modes = [_][]const u8{ "files_with_matches", "content", "count" };
        var valid = false;
        for (valid_modes) |m| {
            if (std.mem.eql(u8, mode, m)) {
                valid = true;
                break;
            }
        }
        if (!valid) return false;
    }

    // Validate type if provided
    if (args.type) |t| {
        if (FileTypeExtensions.get(t) == null) return false;
    }

    // Validate head_limit range
    if (args.head_limit) |hl| {
        if (hl == 0 or hl > 500) return false;
    }

    // Validate max_results range (backwards compat)
    if (args.max_results) |mr| {
        if (mr == 0 or mr > 500) return false;
    }

    // Validate context params (0-10 range)
    if (args.@"-A") |a| {
        if (a > 10) return false;
    }
    if (args.@"-B") |b| {
        if (b > 10) return false;
    }
    if (args.@"-C") |c| {
        if (c > 10) return false;
    }

    // Validate path if provided - block directory traversal
    if (args.path) |p| {
        if (std.mem.startsWith(u8, p, "/")) return false;
        if (std.mem.indexOf(u8, p, "..") != null) return false;
    }

    // Validate file filters if provided
    if (args.glob) |g| {
        if (std.mem.startsWith(u8, g, "/")) return false;
        if (std.mem.indexOf(u8, g, "..") != null) return false;
    }
    if (args.file_filter) |filter| {
        if (std.mem.startsWith(u8, filter, "/")) return false;
        if (std.mem.indexOf(u8, filter, "..") != null) return false;
    }

    return true;
}
