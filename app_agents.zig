// Agent module - handles agent sessions, execution, and result processing
const std = @import("std");
const mem = std.mem;
const ollama = @import("ollama");
const markdown = @import("markdown");
const tools_module = @import("tools");
const message_renderer = @import("message_renderer");
const context_module = @import("context");
pub const agents_module = @import("agents");
const agent_executor = @import("agent_executor");
const task_store_module = @import("task_store");

// Forward declare App type to avoid circular dependency
const App = @import("app.zig").App;

/// Thread function context for background agent execution
pub const AgentThreadContext = struct {
    allocator: mem.Allocator,
    app: *App,
    executor: *agent_executor.AgentExecutor,
    agent_context: agents_module.AgentContext,
    system_prompt: []const u8,
    user_input: []const u8,
    available_tools: []const ollama.Tool,
    progress_ctx: *ProgressDisplayContext,
    is_continuation: bool,

    /// Clean up all owned allocations
    pub fn deinit(self: *AgentThreadContext) void {
        self.progress_ctx.deinit(self.allocator);
        self.allocator.destroy(self.progress_ctx);
        self.allocator.free(self.user_input);
        freeOllamaTools(self.allocator, self.available_tools);
    }
};

/// Tool event for queuing from background thread to main thread
pub const AgentToolEvent = struct {
    event_type: enum { start, complete },
    tool_name: []const u8, // Owned, must be freed
    success: bool = true,
    execution_time_ms: i64 = 0,
    // Display fields for subagent tool call transparency
    arguments: ?[]const u8 = null, // Owned, must be freed
    result: ?[]const u8 = null, // Owned, must be freed
    data_size_bytes: usize = 0,
};

/// Agent command events for deferred dispatch (breaks recursive error set resolution)
/// Instead of kickback functions calling handleAgentCommand directly (which creates
/// recursive error sets), they queue events that the main loop dispatches.
pub const AgentCommandEvent = union(enum) {
    start_questioner: struct {
        task: []const u8, // Owned, must be freed
        display_text: []const u8, // Owned, must be freed
    },
    start_planner: struct {
        prompt: []const u8, // Owned, must be freed
        display_text: []const u8, // Owned, must be freed
    },
    start_tinkerer: struct {
        task: []const u8, // Owned, must be freed
        display_text: []const u8, // Owned, must be freed
    },
    start_judge: struct {
        task: []const u8, // Owned, must be freed
        display_text: []const u8, // Owned, must be freed
    },

    pub fn deinit(self: *AgentCommandEvent, allocator: mem.Allocator) void {
        switch (self.*) {
            .start_questioner => |data| {
                allocator.free(data.task);
                allocator.free(data.display_text);
            },
            .start_planner => |data| {
                allocator.free(data.prompt);
                allocator.free(data.display_text);
            },
            .start_tinkerer => |data| {
                allocator.free(data.task);
                allocator.free(data.display_text);
            },
            .start_judge => |data| {
                allocator.free(data.task);
                allocator.free(data.display_text);
            },
        }
    }
};

/// Agent progress context for streaming sub-agent progress to UI
/// Now uses unified ProgressDisplayContext from agents.zig
pub const ProgressDisplayContext = agents_module.ProgressDisplayContext;

/// Free a slice of Ollama tools and their inner string allocations
pub fn freeOllamaTools(allocator: mem.Allocator, tools: []const ollama.Tool) void {
    for (tools) |tool| {
        allocator.free(tool.function.name);
        allocator.free(tool.function.description);
        allocator.free(tool.function.parameters);
    }
    allocator.free(tools);
}

/// Format tool call display content for subagent tool messages
/// Matches the format used by main agent's ToolResult.formatDisplay()
/// Takes individual fields to work with both ToolProgressData and AgentToolEvent
fn formatToolDisplay(
    allocator: mem.Allocator,
    name: []const u8,
    success: bool,
    execution_time_ms: i64,
    arguments: ?[]const u8,
    result: ?[]const u8,
    data_size_bytes: usize,
) ![]const u8 {
    var display = std.ArrayListUnmanaged(u8){};
    errdefer display.deinit(allocator);
    const writer = display.writer(allocator);

    try writer.print("[Tool: {s}] Status: ", .{name});
    try writer.writeAll(if (success) "✅ SUCCESS" else "❌ FAILED");

    if (result) |r| {
        const preview_len = @min(r.len, 10000);
        try writer.print("\nResult: {s}", .{r[0..preview_len]});
        if (r.len > 10000) {
            try writer.print("... ({d} more bytes)", .{r.len - 10000});
        }
    }

    try writer.print("\nExecution Time: {d}ms", .{execution_time_ms});
    try writer.print("\nData Size: {d} bytes", .{data_size_bytes});

    if (arguments) |args| {
        try writer.print("\nArguments: {s}", .{args});
    }

    return display.toOwnedSlice(allocator);
}

/// Finalize agent message with nice formatting when agent completes
/// Now uses unified finalization from message_renderer
fn finalizeAgentMessage(ctx: *ProgressDisplayContext) !void {
    return message_renderer.finalizeProgressMessage(ctx);
}

/// Progress callback for sub-agents - only handles tool display messages
/// Thinking/content accumulation happens here but final response comes from handleAgentResult
pub fn agentProgressCallback(user_data: ?*anyopaque, update_type: agents_module.ProgressUpdateType, message: []const u8, tool_data: ?*const agents_module.ToolProgressData) void {
    const ctx = @as(*ProgressDisplayContext, @ptrCast(@alignCast(user_data orelse return)));
    const allocator = ctx.app.allocator;

    switch (update_type) {
        .thinking => {
            // Queue chunk for main thread (like main streaming does)
            const chunk_copy = allocator.dupe(u8, message) catch return;
            ctx.app.stream_mutex.lock();
            defer ctx.app.stream_mutex.unlock();
            ctx.app.stream_chunks.append(allocator, .{
                .thinking = chunk_copy,
                .content = null,
                .done = false,
            }) catch {
                allocator.free(chunk_copy);
                return;
            };
            // Also accumulate for stats/final formatting
            ctx.thinking_buffer.appendSlice(allocator, message) catch return;
        },
        .content => {
            // Queue chunk for main thread (like main streaming does)
            const chunk_copy = allocator.dupe(u8, message) catch return;
            ctx.app.stream_mutex.lock();
            defer ctx.app.stream_mutex.unlock();
            ctx.app.stream_chunks.append(allocator, .{
                .thinking = null,
                .content = chunk_copy,
                .done = false,
            }) catch {
                allocator.free(chunk_copy);
                return;
            };
            // Also accumulate for stats/final formatting
            ctx.content_buffer.appendSlice(allocator, message) catch return;
        },
        .complete => {
            // Per-iteration complete - don't send done chunk here
            // The done chunk is sent from agentThreadFn when agent fully finishes
            // This allows multi-iteration agents (with tool calls) to keep streaming
        },
        .iteration, .tool_call => {
            // Status updates - ignore
        },
        .tool_start => {
            // Queue event for main thread when running in background
            if (ctx.is_background_thread) {
                const tool_name_copy = allocator.dupe(u8, message) catch return;
                ctx.app.agent_result_mutex.lock();
                defer ctx.app.agent_result_mutex.unlock();
                ctx.app.agent_tool_events.append(allocator, .{
                    .event_type = .start,
                    .tool_name = tool_name_copy,
                }) catch {
                    allocator.free(tool_name_copy);
                    return;
                };
                return;
            }

            // Add placeholder tool message (will be updated on complete)
            // Silently ignore allocation failures in UI callback - non-critical path
            const tool_name = allocator.dupe(u8, message) catch return;
            errdefer allocator.free(tool_name);

            const content = allocator.dupe(u8, "") catch return;
            errdefer allocator.free(content);

            ctx.app.messages.append(allocator, .{
                .role = .display_only_data,
                .content = content,
                .processed_content = .{},
                .timestamp = std.time.milliTimestamp(),
                .tool_call_expanded = false,
                .tool_name = tool_name,
                .tool_success = null,
                .tool_execution_time = null,
            }) catch return;
            // On success, ownership transferred to messages array
            ctx.current_tool_message_idx = ctx.app.messages.items.len - 1;
            // Silently ignore redraw failures - UI will update on next event
            _ = message_renderer.redrawScreen(ctx.app) catch return;
        },
        .tool_complete => {
            // Queue event for main thread when running in background
            if (ctx.is_background_thread) {
                const data = tool_data orelse return;
                const tool_name_copy = allocator.dupe(u8, data.name) catch return;
                // Copy arguments and result for display
                const args_copy = if (data.arguments) |a| allocator.dupe(u8, a) catch null else null;
                const result_copy = if (data.result) |r| allocator.dupe(u8, r) catch null else null;

                ctx.app.agent_result_mutex.lock();
                defer ctx.app.agent_result_mutex.unlock();
                ctx.app.agent_tool_events.append(allocator, .{
                    .event_type = .complete,
                    .tool_name = tool_name_copy,
                    .success = data.success,
                    .execution_time_ms = data.execution_time_ms,
                    .arguments = args_copy,
                    .result = result_copy,
                    .data_size_bytes = data.data_size_bytes,
                }) catch {
                    allocator.free(tool_name_copy);
                    if (args_copy) |a| allocator.free(a);
                    if (result_copy) |r| allocator.free(r);
                    return;
                };
                return;
            }

            // Read from structured tool_data instead of parsing string
            const data = tool_data orelse return;
            if (ctx.current_tool_message_idx) |idx| {
                var msg = &ctx.app.messages.items[idx];
                msg.tool_success = data.success;
                msg.tool_execution_time = data.execution_time_ms;

                // Format and set display content for tool call transparency
                const display_content = formatToolDisplay(
                    allocator,
                    data.name,
                    data.success,
                    data.execution_time_ms,
                    data.arguments,
                    data.result,
                    data.data_size_bytes,
                ) catch return;

                // Free old empty content
                allocator.free(msg.content);
                for (msg.processed_content.items) |*item| {
                    item.deinit(allocator);
                }
                msg.processed_content.deinit(allocator);

                msg.content = display_content;
                msg.processed_content = markdown.processMarkdown(allocator, display_content) catch .{};
            }
            ctx.current_tool_message_idx = null;
            // Silently ignore redraw failures - UI will update on next event
            _ = message_renderer.redrawScreen(ctx.app) catch return;
        },
        .embedding, .storage => {
            // Embedding/storage updates not used in current architecture
        },
    }
}

/// Background thread function for agent execution
pub fn agentThreadFn(ctx: *AgentThreadContext) void {
    // Helper to create error result
    const makeErrorResult = struct {
        fn f(allocator: mem.Allocator, err: anyerror) agents_module.AgentResult {
            return .{
                .success = false,
                .status = .failed,
                .data = null,
                .error_message = std.fmt.allocPrint(allocator, "Agent error: {s}", .{@errorName(err)}) catch null,
                .stats = .{
                    .iterations_used = 0,
                    .tool_calls_made = 0,
                    .execution_time_ms = 0,
                },
            };
        }
    }.f;

    // Run the agent (blocking in this thread, non-blocking from main thread's perspective)
    const result: agents_module.AgentResult = if (ctx.is_continuation)
        ctx.executor.resumeWithUserInput(
            ctx.agent_context,
            ctx.system_prompt,
            ctx.user_input,
            ctx.available_tools,
            agentProgressCallback,
            @ptrCast(ctx.progress_ctx),
        ) catch |err| makeErrorResult(ctx.allocator, err)
    else
        ctx.executor.run(
            ctx.agent_context,
            ctx.system_prompt,
            ctx.user_input,
            ctx.available_tools,
            agentProgressCallback,
            @ptrCast(ctx.progress_ctx),
        ) catch |err| makeErrorResult(ctx.allocator, err);

    // Send "done" chunk to signal streaming complete
    // This must happen AFTER all iterations finish, not per-iteration
    {
        ctx.app.stream_mutex.lock();
        defer ctx.app.stream_mutex.unlock();
        ctx.app.stream_chunks.append(ctx.allocator, .{
            .thinking = null,
            .content = null,
            .done = true,
        }) catch |err| {
            std.log.warn("Failed to append done chunk: {}", .{err});
        };
    }

    // Store result for main thread to pick up
    ctx.app.agent_result_mutex.lock();
    defer ctx.app.agent_result_mutex.unlock();
    ctx.app.agent_result = result;
    ctx.app.agent_result_ready = true;
}

/// Handle agent slash command (e.g., /agentname or /agentname task)
/// full_input is the complete user input for display (e.g., "/planner hello")
pub fn handleAgentCommand(app: *App, agent_name: []const u8, task: ?[]const u8, full_input: []const u8) !void {
    // If this agent is already active, end the session
    if (app.app_context.active_agent) |active| {
        if (mem.eql(u8, active.agent_name, agent_name)) {
            // Check if this was the planner being ended - trigger questioner
            const was_planner = mem.eql(u8, active.agent_name, "planner");
            try endAgentSession(app);
            if (was_planner) {
                // Queue questioner event for main loop dispatch
                triggerQuestioner(app);
            }
            return;
        }
    }

    // If a different agent is active, end it first
    if (app.app_context.active_agent != null) {
        try endAgentSession(app);
    }

    // Start new agent session if task provided
    if (task) |t| {
        try startAgentSession(app, agent_name, t, full_input);
    } else {
        // Just `/agentname` with no task - show usage hint
        const hint_content = try std.fmt.allocPrint(
            app.allocator,
            "🤖 **{s}** - Type `/{s} <your task>` to start a conversation, or `/{s}` to end an active session.",
            .{ agent_name, agent_name, agent_name },
        );
        const hint_processed = try markdown.processMarkdown(app.allocator, hint_content);

        try app.messages.append(app.allocator, .{
            .role = .display_only_data,
            .content = hint_content,
            .processed_content = hint_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        });
        _ = try message_renderer.redrawScreen(app);
        app.updateCursorToBottom();
    }
}

/// Start a new agent conversation session
/// display_text is the full user input for display (e.g., "/planner hello")
fn startAgentSession(app: *App, agent_name: []const u8, initial_task: []const u8, display_text: []const u8) !void {
    const registry = app.app_context.agent_registry orelse return;
    const agent_def = registry.get(agent_name) orelse return;

    // Create heap-allocated executor
    const executor = try app.allocator.create(agent_executor.AgentExecutor);
    executor.* = agent_executor.AgentExecutor.init(app.allocator, agent_def.capabilities);
    executor.agent_name = try app.allocator.dupe(u8, agent_name);

    // Create session state with type-safe executor interface
    const session = try app.allocator.create(context_module.ActiveAgentSession);
    session.* = .{
        .executor = executor.interface(),
        .agent_name = try app.allocator.dupe(u8, agent_name),
        .system_prompt = agent_def.system_prompt,
        .capabilities = agent_def.capabilities,
    };
    app.app_context.active_agent = session;

    // Send initial task to agent - pass display_text for the user message
    try sendToAgent(app, initial_task, display_text);
}

/// Send user input to the active agent (non-blocking)
/// display_text: optional text to show in UI (e.g., "/planner hello"), if null uses user_input
pub fn sendToAgent(app: *App, user_input: []const u8, display_text: ?[]const u8) !void {
    const session = app.app_context.active_agent orelse return;

    // Guard against spawning while a thread is already running
    // Must be checked BEFORE any side effects (messages, UI updates, allocations)
    if (app.agent_thread != null) {
        return error.AgentThreadAlreadyRunning;
    }

    // Use display_text if provided, otherwise use user_input for display
    const message_to_show = display_text orelse user_input;

    // Display user message with full text (including slash command if initial)
    const user_content = try app.allocator.dupe(u8, message_to_show);
    const user_processed = try markdown.processMarkdown(app.allocator, user_content);

    try app.messages.append(app.allocator, .{
        .role = .user,
        .content = user_content,
        .agent_source = try app.allocator.dupe(u8, session.agent_name),
        .processed_content = user_processed,
        .thinking_expanded = true,
        .timestamp = std.time.milliTimestamp(),
    });
    try app.persistMessage(app.messages.items.len - 1);

    // Set agent responding flag BEFORE redraw so taskbar shows status
    app.agent_responding = true;

    // Create empty assistant placeholder (will be filled by streaming)
    const assistant_content = try app.allocator.dupe(u8, "");
    const assistant_processed = try markdown.processMarkdown(app.allocator, assistant_content);
    try app.messages.append(app.allocator, .{
        .role = .assistant,
        .content = assistant_content,
        .agent_source = try app.allocator.dupe(u8, session.agent_name),
        .processed_content = assistant_processed,
        .thinking_content = null,
        .thinking_expanded = true,
        .timestamp = std.time.milliTimestamp(),
    });

    // Enable streaming mode and track the specific message to update
    // (important: tool messages may be inserted, so we can't just use "last message")
    app.streaming_active = true;
    app.streaming_message_idx = app.messages.items.len - 1;

    _ = try message_renderer.redrawScreen(app);
    app.updateCursorToBottom();

    // Get the executor through the type-safe interface
    const executor: *agent_executor.AgentExecutor = @ptrCast(@alignCast(session.executor.ptr));

    // Check if this is initial message or continuation (use thread-safe accessor)
    const is_continuation = session.executor.getMessageHistoryLen() > 0;

    // Allocate thread context and owned data
    const thread_ctx = try app.allocator.create(AgentThreadContext);
    errdefer app.allocator.destroy(thread_ctx);

    // Allocate progress context on heap (owned by thread)
    const progress_ctx = try app.allocator.create(ProgressDisplayContext);
    errdefer app.allocator.destroy(progress_ctx);
    progress_ctx.* = .{
        .app = app,
        .current_message_idx = app.messages.items.len - 1, // Index of assistant placeholder
        .task_name = try app.allocator.dupe(u8, session.agent_name),
        .task_name_owned = true,
        .task_icon = "🤖",
        .start_time = std.time.milliTimestamp(),
        .is_background_thread = true, // Routes chunks through stream_chunks queue
    };

    // Get available tools (owned by thread context)
    const available_tools = try tools_module.getOllamaTools(app.allocator);

    // Dupe user_input for thread ownership
    const owned_user_input = try app.allocator.dupe(u8, user_input);

    // Build agent context with full access to app resources
    const agent_context = agents_module.AgentContext{
        .allocator = app.allocator,
        .llm_provider = &app.llm_provider,
        .config = &app.config,
        .system_prompt = session.system_prompt,
        .capabilities = session.capabilities,
        .vector_store = app.app_context.vector_store,
        .embedder = app.app_context.embedder,
        .recent_messages = null,
        .conversation_db = app.app_context.conversation_db,
        .session_id = app.app_context.session_id,
        // Task memory system
        .task_store = app.app_context.task_store,
        .task_db = app.app_context.task_db,
        .git_sync = app.app_context.git_sync,
        // Application state for todo/file tracking
        .state = app.app_context.state,
        // Agent registry for nested agent calls
        .agent_registry = app.app_context.agent_registry,
    };

    thread_ctx.* = .{
        .allocator = app.allocator,
        .app = app,
        .executor = executor,
        .agent_context = agent_context,
        .system_prompt = session.system_prompt,
        .user_input = owned_user_input,
        .available_tools = available_tools,
        .progress_ctx = progress_ctx,
        .is_continuation = is_continuation,
    };

    // Store context and spawn thread
    app.agent_thread_ctx = thread_ctx;
    app.agent_thread = try std.Thread.spawn(.{}, agentThreadFn, .{thread_ctx});

    // Returns immediately - main event loop polls for completion
}

/// Finalize the existing streamed agent message with prefix and persist
fn finalizeAgentStreamedMessage(
    app: *App,
    agent_name: []const u8,
    success: bool,
) !void {
    if (app.messages.items.len == 0) return;

    var last_message = &app.messages.items[app.messages.items.len - 1];
    if (last_message.role != .assistant) return;

    // Build new content with agent prefix
    const prefix = if (success)
        try std.fmt.allocPrint(app.allocator, "🤖 **{s}**:\n\n", .{agent_name})
    else
        try std.fmt.allocPrint(app.allocator, "🤖 **{s}** failed:\n\n", .{agent_name});
    defer app.allocator.free(prefix);

    const new_content = try std.fmt.allocPrint(
        app.allocator,
        "{s}{s}",
        .{ prefix, last_message.content },
    );

    // Free old content and replace
    app.allocator.free(last_message.content);
    for (last_message.processed_content.items) |*item| {
        item.deinit(app.allocator);
    }
    last_message.processed_content.deinit(app.allocator);

    last_message.content = new_content;
    last_message.processed_content = try markdown.processMarkdown(app.allocator, new_content);

    // Collapse thinking when done
    last_message.thinking_expanded = false;

    // Persist the finalized message
    try app.persistMessage(app.messages.items.len - 1);
    _ = try message_renderer.redrawScreen(app);
    app.updateCursorToBottom();
}

/// Handle the result from an agent execution
pub fn handleAgentResult(app: *App, result: *agents_module.AgentResult) !void {
    defer result.deinit(app.allocator);
    const session = app.app_context.active_agent orelse return;

    // Capture agent name before session is cleaned up
    const agent_name_copy = try app.allocator.dupe(u8, session.agent_name);
    defer app.allocator.free(agent_name_copy);

    if (result.status == .complete or result.status == .failed) {
        // Agent finished - finalize the streamed message and end session
        // The message content was already populated via streaming
        // We just need to add the agent prefix and handle any error case
        if (!result.success) {
            // For errors, we need to replace content with error message
            if (app.messages.items.len > 0) {
                var last_message = &app.messages.items[app.messages.items.len - 1];
                if (last_message.role == .assistant) {
                    // Free existing content
                    app.allocator.free(last_message.content);
                    for (last_message.processed_content.items) |*item| {
                        item.deinit(app.allocator);
                    }
                    last_message.processed_content.deinit(app.allocator);

                    // Set error message
                    const error_msg = result.error_message orelse "unknown error";
                    last_message.content = try app.allocator.dupe(u8, error_msg);
                    last_message.processed_content = try markdown.processMarkdown(app.allocator, last_message.content);
                }
            }
        }

        try finalizeAgentStreamedMessage(app, agent_name_copy, result.success);
        try endAgentSession(app);

        // Trigger questioner after planner completes successfully
        if (result.success and mem.eql(u8, agent_name_copy, "planner")) {
            triggerQuestioner(app);
        }

        // Kickback orchestration: when questioner completes, check for blocked tasks
        if (result.success and mem.eql(u8, agent_name_copy, "questioner")) {
            handleQuestionerComplete(app);
        }

        // Tinkerer → routing based on whether task was blocked
        if (result.success and mem.eql(u8, agent_name_copy, "tinkerer")) {
            if (hasBlockedTasks(app)) {
                // Tinkerer explicitly blocked - go to Planner for decomposition
                triggerPlannerKickback(app);
            } else {
                // Either complete or max iterations - Judge reviews the work
                triggerJudge(app);
            }
        }

        // Judge completion: either move to next task or trigger revision retry
        if (result.success and mem.eql(u8, agent_name_copy, "judge")) {
            handleJudgeComplete(app);
        }
    } else if (result.status == .needs_input) {
        // Conversation mode: agent responded, waiting for user input
        // Finalize the streamed message but keep session alive
        try finalizeAgentStreamedMessage(app, agent_name_copy, true);
    }
}

/// Trigger Questioner to evaluate the next ready task
/// Used after Planner completes and after Judge approves a task
pub fn triggerQuestioner(app: *App) void {
    const registry = app.app_context.agent_registry orelse return;
    if (registry.get("questioner") == null) return;

    const task = app.allocator.dupe(u8, "Evaluate next task") catch return;
    const display = app.allocator.dupe(u8, "/questioner Evaluate next task") catch {
        app.allocator.free(task);
        return;
    };

    app.agent_command_events.append(app.allocator, .{
        .start_questioner = .{ .task = task, .display_text = display },
    }) catch {
        app.allocator.free(task);
        app.allocator.free(display);
    };
}

/// Trigger Tinkerer to work on next ready task
pub fn triggerTinkerer(app: *App) void {
    const registry = app.app_context.agent_registry orelse return;
    if (registry.get("tinkerer") == null) return;

    const task = app.allocator.dupe(u8, "Implement the next ready task") catch return;
    const display = app.allocator.dupe(u8, "/tinkerer Implement next ready task") catch {
        app.allocator.free(task);
        return;
    };

    app.agent_command_events.append(app.allocator, .{
        .start_tinkerer = .{ .task = task, .display_text = display },
    }) catch {
        app.allocator.free(task);
        app.allocator.free(display);
    };
}

/// Trigger Judge to review Tinkerer's implementation
pub fn triggerJudge(app: *App) void {
    const registry = app.app_context.agent_registry orelse return;
    if (registry.get("judge") == null) return;

    const task = app.allocator.dupe(u8, "Review the staged implementation") catch return;
    const display = app.allocator.dupe(u8, "/judge Review implementation") catch {
        app.allocator.free(task);
        return;
    };

    app.agent_command_events.append(app.allocator, .{
        .start_judge = .{ .task = task, .display_text = display },
    }) catch {
        app.allocator.free(task);
        app.allocator.free(display);
    };
}

/// Handle Judge completion - either move to next task or retry Tinkerer
pub fn handleJudgeComplete(app: *App) void {
    const task_store = app.app_context.task_store orelse return;

    // Check if Judge rejected (look for REJECTED: comment from judge)
    // Note: complete_task changes status to completed, so if still in_progress
    // with recent rejection, it means Judge rejected
    if (task_store.getCurrentInProgressTask()) |task| {
        // Find most recent REJECTED: comment
        var i = task.comments.len;
        while (i > 0) {
            i -= 1;
            const comment = task.comments[i];
            if (std.mem.startsWith(u8, comment.content, "REJECTED:")) {
                // Extract feedback from comment
                var feedback = comment.content[9..]; // Skip "REJECTED:"
                while (feedback.len > 0 and feedback[0] == ' ') {
                    feedback = feedback[1..];
                }
                // Judge rejected - trigger Tinkerer to retry
                triggerTinkererRevision(app, &task.id, feedback);
                return;
            } else if (std.mem.startsWith(u8, comment.content, "SUMMARY:") or
                std.mem.startsWith(u8, comment.content, "APPROVED:"))
            {
                // If we see SUMMARY or APPROVED before REJECTED, no rejection pending
                break;
            }
        }
    }

    // Judge approved (or no current task) - check for next ready task
    const ready_tasks = task_store.getReadyTasks() catch return;
    defer app.allocator.free(ready_tasks);

    if (ready_tasks.len > 0) {
        // More tasks to do - questioner evaluates before tinkerer implements
        triggerQuestioner(app);
    }
    // else: All tasks complete, execution loop ends
}

/// Trigger Tinkerer to retry with revision feedback
pub fn triggerTinkererRevision(app: *App, task_id: *const [8]u8, feedback: []const u8) void {
    const registry = app.app_context.agent_registry orelse return;
    if (registry.get("tinkerer") == null) return;

    const prompt = std.fmt.allocPrint(
        app.allocator,
        "REVISION: Your previous implementation was rejected.\n\nFeedback:\n{s}\n\nPlease address these issues.",
        .{feedback},
    ) catch return;

    const display = std.fmt.allocPrint(
        app.allocator,
        "/tinkerer [REVISION] Fix task {s}",
        .{task_id},
    ) catch {
        app.allocator.free(prompt);
        return;
    };

    app.agent_command_events.append(app.allocator, .{
        .start_tinkerer = .{ .task = prompt, .display_text = display },
    }) catch {
        app.allocator.free(prompt);
        app.allocator.free(display);
    };
}

/// Handle questioner completion - either trigger tinkerer or planner for blocked tasks
pub fn handleQuestionerComplete(app: *App) void {
    // Check for ready tasks FIRST - prioritize work over decomposition
    if (hasReadyTasks(app)) {
        triggerTinkerer(app);
    } else if (hasBlockedTasks(app)) {
        // Only kick back to planner if there's NO ready work
        triggerPlannerKickback(app);
    }
    // else: no work to do, execution loop ends
}

/// Check if there are any tasks with blocked status
fn hasBlockedTasks(app: *App) bool {
    const task_store = app.app_context.task_store orelse return false;
    const counts = task_store.getTaskCounts();
    return counts.blocked > 0;
}

/// Check if there are any ready tasks (pending, no blockers, not molecules)
fn hasReadyTasks(app: *App) bool {
    const task_store = app.app_context.task_store orelse return false;
    const ready = task_store.getReadyTasks() catch return false;
    defer app.allocator.free(ready);
    return ready.len > 0;
}

/// Trigger planner to decompose blocked tasks
fn triggerPlannerKickback(app: *App) void {
    const task_store = app.app_context.task_store orelse return;
    const registry = app.app_context.agent_registry orelse return;

    if (registry.get("planner") == null) {
        return;
    }

    // Get tasks that are actually in blocked status
    const tasks_with_blocked_comments = task_store.getTasksWithCommentPrefix("BLOCKED:") catch return;
    defer app.allocator.free(tasks_with_blocked_comments);

    // Filter to only tasks that are actually blocked
    var actually_blocked = std.ArrayListUnmanaged(task_store_module.Task){};
    defer actually_blocked.deinit(app.allocator);
    for (tasks_with_blocked_comments) |task| {
        if (task.status == .blocked) {
            actually_blocked.append(app.allocator, task) catch continue;
        }
    }

    if (actually_blocked.items.len == 0) {
        // No blocked tasks found - nothing to do
        return;
    }

    // Build prompt for planner with blocked task info
    var prompt = std.ArrayListUnmanaged(u8){};
    defer prompt.deinit(app.allocator);

    prompt.appendSlice(app.allocator, "KICKBACK: The following tasks were blocked and need decomposition:\n\n") catch return;

    for (actually_blocked.items) |task| {
        // Find most recent BLOCKED: comment to extract reason
        var blocked_reason: []const u8 = "No reason provided";
        var i = task.comments.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.startsWith(u8, task.comments[i].content, "BLOCKED:")) {
                var reason = task.comments[i].content[8..];
                while (reason.len > 0 and reason[0] == ' ') {
                    reason = reason[1..];
                }
                blocked_reason = reason;
                break;
            }
        }

        prompt.writer(app.allocator).print("- Task {s}: \"{s}\"\n  Reason: {s}\n\n", .{
            &task.id,
            task.title,
            blocked_reason,
        }) catch return;
    }

    prompt.appendSlice(app.allocator, "Please use update_task to convert these blocked tasks to molecules, then add subtasks to decompose them.") catch return;

    // Create owned copies for the event
    const prompt_str = app.allocator.dupe(u8, prompt.items) catch return;
    const display_text = std.fmt.allocPrint(app.allocator, "/planner [KICKBACK] Decomposing {d} blocked task(s)", .{actually_blocked.items.len}) catch {
        app.allocator.free(prompt_str);
        return;
    };

    // Queue event for main loop dispatch
    app.agent_command_events.append(app.allocator, .{
        .start_planner = .{ .prompt = prompt_str, .display_text = display_text },
    }) catch {
        app.allocator.free(prompt_str);
        app.allocator.free(display_text);
    };
}

/// Process queued agent command events (main loop calls this)
/// Returns true if an agent was started, false otherwise
pub fn processAgentCommandEvents(app: *App) !bool {
    if (app.agent_command_events.items.len == 0) return false;

    // Don't process if an agent is already running
    if (app.agent_thread != null) return false;
    if (app.app_context.active_agent != null) return false;

    // Pop first event (FIFO order)
    var event = app.agent_command_events.orderedRemove(0);
    defer event.deinit(app.allocator);

    switch (event) {
        .start_questioner => |data| {
            handleAgentCommand(app, "questioner", data.task, data.display_text) catch |err| {
                std.log.warn("Failed to start questioner in kickback: {}", .{err});
            };
            return true;
        },
        .start_planner => |data| {
            handleAgentCommand(app, "planner", data.prompt, data.display_text) catch |err| {
                std.log.warn("Failed to start planner in kickback: {}", .{err});
            };
            return true;
        },
        .start_tinkerer => |data| {
            handleAgentCommand(app, "tinkerer", data.task, data.display_text) catch |err| {
                std.log.warn("Failed to start tinkerer: {}", .{err});
            };
            return true;
        },
        .start_judge => |data| {
            handleAgentCommand(app, "judge", data.task, data.display_text) catch |err| {
                std.log.warn("Failed to start judge: {}", .{err});
            };
            return true;
        },
    }
}

/// End the current agent conversation session
pub fn endAgentSession(app: *App) !void {
    const session = app.app_context.active_agent orelse return;

    // FIRST: Mark session as ended so new messages don't route here
    // This must happen before any operations that can throw
    app.app_context.active_agent = null;

    // CRITICAL: Wait for agent thread to finish before cleaning up executor
    // The thread uses the executor's message_history, so we must join first
    if (app.agent_thread) |thread| {
        thread.join();
        app.agent_thread = null;
    }
    // Clean up thread context
    if (app.agent_thread_ctx) |ctx| {
        ctx.deinit();
        app.allocator.destroy(ctx);
        app.agent_thread_ctx = null;
    }
    // Clean up any pending agent result
    if (app.agent_result) |*result| {
        result.deinit(app.allocator);
        app.agent_result = null;
    }
    app.agent_result_ready = false;
    app.agent_responding = false;

    // Clean up streaming state (agent sets streaming_active when it starts)
    app.streaming_active = false;
    app.streaming_message_idx = null;

    // Clear any pending stream chunks from the terminated agent
    {
        app.stream_mutex.lock();
        defer app.stream_mutex.unlock();
        for (app.stream_chunks.items) |chunk| {
            if (chunk.thinking) |t| app.allocator.free(t);
            if (chunk.content) |c| app.allocator.free(c);
        }
        app.stream_chunks.clearRetainingCapacity();
    }

    // Ensure session cleanup happens regardless of later errors
    defer {
        app.allocator.free(session.agent_name);
        app.allocator.destroy(session);
    }

    // Clean up executor through the type-safe interface
    const executor: *agent_executor.AgentExecutor = @ptrCast(@alignCast(session.executor.ptr));
    session.executor.deinit(); // Use interface method for type safety
    app.allocator.destroy(executor);

    // Show session ended message (can throw, session cleanup is deferred)
    const end_content = try std.fmt.allocPrint(
        app.allocator,
        "🤖 **{s}** session ended.",
        .{session.agent_name},
    );
    const end_processed = try markdown.processMarkdown(app.allocator, end_content);

    try app.messages.append(app.allocator, .{
        .role = .display_only_data,
        .content = end_content,
        .processed_content = end_processed,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
    });
    _ = try message_renderer.redrawScreen(app);
    app.updateCursorToBottom();
}

/// Process any queued tool events from background agent thread
pub fn processAgentToolEvents(app: *App) !void {
    if (app.agent_thread == null) return;

    // Process any queued tool events from background thread
    app.agent_result_mutex.lock();
    const events_to_process = app.agent_tool_events.toOwnedSlice(app.allocator) catch null;
    app.agent_result_mutex.unlock();

    // Process tool events outside the mutex
    if (events_to_process) |events| {
        defer app.allocator.free(events);
        var current_tool_idx: ?usize = null;

        for (events) |*event| {
            defer {
                app.allocator.free(event.tool_name);
                if (event.arguments) |a| app.allocator.free(a);
                if (event.result) |r| app.allocator.free(r);
            }

            switch (event.event_type) {
                .start => {
                    // Add placeholder tool message
                    const tool_name = app.allocator.dupe(u8, event.tool_name) catch continue;
                    const content = app.allocator.dupe(u8, "") catch {
                        app.allocator.free(tool_name);
                        continue;
                    };

                    app.messages.append(app.allocator, .{
                        .role = .display_only_data,
                        .content = content,
                        .processed_content = .{},
                        .timestamp = std.time.milliTimestamp(),
                        .tool_call_expanded = false,
                        .tool_name = tool_name,
                        .tool_success = null,
                        .tool_execution_time = null,
                    }) catch continue;
                    current_tool_idx = app.messages.items.len - 1;
                },
                .complete => {
                    // Update the tool message with results
                    if (current_tool_idx) |idx| {
                        var msg = &app.messages.items[idx];
                        msg.tool_success = event.success;
                        msg.tool_execution_time = event.execution_time_ms;

                        // Format and set display content for tool call transparency
                        if (formatToolDisplay(
                            app.allocator,
                            event.tool_name,
                            event.success,
                            event.execution_time_ms,
                            event.arguments,
                            event.result,
                            event.data_size_bytes,
                        )) |display_content| {
                            // Free old empty content
                            app.allocator.free(msg.content);
                            for (msg.processed_content.items) |*item| {
                                item.deinit(app.allocator);
                            }
                            msg.processed_content.deinit(app.allocator);

                            msg.content = display_content;
                            msg.processed_content = markdown.processMarkdown(app.allocator, display_content) catch .{};
                        } else |_| {}
                    }
                    current_tool_idx = null;
                },
            }
        }

        // Redraw after processing events
        if (events.len > 0) {
            _ = message_renderer.redrawScreen(app) catch {};
            app.updateCursorToBottom();
        }
    }
}

/// Poll for agent completion (non-blocking)
/// Returns true if a result was processed
pub fn pollAgentResult(app: *App) !bool {
    if (app.agent_thread == null) return false;

    app.agent_result_mutex.lock();
    const result_ready = app.agent_result_ready;
    app.agent_result_mutex.unlock();

    if (!result_ready) return false;

    // Agent finished - join thread and process result
    if (app.agent_thread) |thread| {
        thread.join();
        app.agent_thread = null;
    }

    // Get the result (protected by mutex)
    app.agent_result_mutex.lock();
    var result = app.agent_result;
    app.agent_result = null;
    app.agent_result_ready = false;
    app.agent_result_mutex.unlock();

    // Clean up thread context
    if (app.agent_thread_ctx) |ctx| {
        ctx.deinit();
        app.allocator.destroy(ctx);
        app.agent_thread_ctx = null;
    }

    // Process the result
    if (result) |*r| {
        try handleAgentResult(app, r);
    }

    return true;
}
