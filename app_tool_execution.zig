// Tool execution module - handles tool permission prompts and execution state machine
const std = @import("std");
const mem = std.mem;
const ollama = @import("ollama");
const markdown = @import("markdown");
const permission = @import("permission");
const tools_module = @import("tools");
const message_renderer = @import("message_renderer");
const tool_executor_module = @import("tool_executor");
const types = @import("types");
pub const agents_module = @import("agents");

// Forward declare App type to avoid circular dependency
const App = @import("app.zig").App;

// Import streaming module for startStreaming
const app_streaming = @import("app_streaming.zig");

// Import agent module for progress callback and context
const app_agents = @import("app_agents.zig");

// Import message loader for virtualization
const message_loader = @import("message_loader");

/// Result of tool execution tick
pub const ToolTickResult = enum {
    no_action,
    needs_redraw,
    iteration_complete,
    iteration_limit,
};

/// Show permission prompt for a tool call (non-blocking)
pub fn showPermissionPrompt(
    app: *App,
    tool_call: ollama.ToolCall,
    eval_result: permission.PolicyEngine.EvaluationResult,
) !void {
    // Create permission request message
    const prompt_text = try std.fmt.allocPrint(
        app.allocator,
        "Permission requested for tool: {s}",
        .{tool_call.function.name},
    );
    const prompt_processed = try markdown.processMarkdown(app.allocator, prompt_text);

    // Duplicate tool call for storage in message
    const stored_tool_call = ollama.ToolCall{
        .id = if (tool_call.id) |id| try app.allocator.dupe(u8, id) else null,
        .type = if (tool_call.type) |t| try app.allocator.dupe(u8, t) else null,
        .function = .{
            .name = try app.allocator.dupe(u8, tool_call.function.name),
            .arguments = try app.allocator.dupe(u8, tool_call.function.arguments),
        },
    };

    try app.messages.append(app.allocator, .{
        .role = .display_only_data,
        .content = prompt_text,
        .processed_content = prompt_processed,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
        .permission_request = .{
            .tool_call = stored_tool_call,
            .eval_result = .{
                .allowed = eval_result.allowed,
                .reason = try app.allocator.dupe(u8, eval_result.reason),
                .ask_user = eval_result.ask_user,
                .show_preview = eval_result.show_preview,
            },
            .timestamp = std.time.milliTimestamp(),
        },
    });
    message_loader.onMessageAdded(app);

    // Persist permission request immediately
    try app.persistMessage(app.messages.items.len - 1);

    // Set permission pending state (non-blocking - main loop will handle response)
    app.permission_pending = true;
    app.permission_response = null;
}

/// Execute a tool call and return the result (Phase 1: passes AppContext)
pub fn executeTool(app: *App, tool_call: ollama.ToolCall) !tools_module.ToolResult {
    // Populate conversation context for context-aware tools
    // Extract last 5 messages (or fewer if conversation is shorter)
    const start_idx = if (app.messages.items.len > 5)
        app.messages.items.len - 5
    else
        0;

    // IMPORTANT: Allocate a COPY of the messages slice to avoid use-after-free
    // During tool execution, app.messages may grow and reallocate its backing buffer
    // This would invalidate any slice pointing into the old buffer
    const messages_copy = try app.allocator.dupe(types.Message, app.messages.items[start_idx..]);
    app.app_context.recent_messages = messages_copy;
    defer app.allocator.free(messages_copy);

    // Set up agent progress streaming for sub-agents (like file curator)
    var agent_progress_ctx = app_agents.ProgressDisplayContext{
        .app = app,
        .task_name = try app.allocator.dupe(u8, "Agent Analysis"), // Generic default (will be updated by run_agent tool)
        .task_name_owned = true, // We allocated task_name, so we own it
        .task_icon = "🤔", // Default icon for file analysis
        .start_time = std.time.milliTimestamp(), // Start tracking execution time
    };
    defer agent_progress_ctx.deinit(app.allocator);

    app.app_context.agent_progress_callback = app_agents.agentProgressCallback;
    app.app_context.agent_progress_user_data = &agent_progress_ctx;

    // Execute tool with conversation context and progress streaming
    const result = try tools_module.executeToolCall(app.allocator, tool_call, &app.app_context);

    // Note: Progress message is kept as permanent "Agent Analysis" message
    // It was already finalized by the progress callback when agent completed

    // Clear conversation context and progress callback after use
    app.app_context.recent_messages = null;
    app.app_context.agent_progress_callback = null;
    app.app_context.agent_progress_user_data = null;

    return result;
}

/// Process one tick of the tool execution state machine
/// Returns what action the caller should take
pub fn tickToolExecution(app: *App) !ToolTickResult {
    if (!app.tool_executor.hasPendingWork()) {
        return .no_action;
    }

    // Forward permission response from App to tool_executor if available
    if (app.permission_response) |response| {
        app.tool_executor.setPermissionResponse(response);
        app.permission_response = null;
    }

    // Advance the state machine
    const tick_result = try app.tool_executor.tick(
        &app.permission_manager,
        app.state.iteration_count,
        app.max_iterations,
    );

    switch (tick_result) {
        .no_action => {
            // Nothing to do - waiting for user input or other event
            return .no_action;
        },

        .show_permission_prompt => {
            // Tool executor needs to ask user for permission
            if (app.tool_executor.getPendingPermissionTool()) |tool_call| {
                if (app.tool_executor.getPendingPermissionEval()) |eval_result| {
                    try showPermissionPrompt(app, tool_call, eval_result);
                    app.permission_pending = true;
                    _ = try message_renderer.redrawScreen(app);
                    app.updateCursorToBottom();
                }
            }
            return .needs_redraw;
        },

        .render_requested => {
            // Tool executor is ready to execute current tool (if in executing state)
            if (app.tool_executor.getCurrentState() == .executing) {
                if (app.tool_executor.getCurrentToolCall()) |tool_call| {
                    try executeCurrentTool(app, tool_call);
                }
            } else if (app.tool_executor.getCurrentState() == .creating_denial_result) {
                // User denied permission - create error result for LLM
                if (app.tool_executor.getCurrentToolCall()) |tool_call| {
                    try createDenialResult(app, tool_call);
                }
            } else {
                // Just redraw for other states
                _ = try message_renderer.redrawScreen(app);
            }
            return .needs_redraw;
        },

        .iteration_complete => {
            // All tools executed - increment iteration and continue streaming
            app.state.iteration_count += 1;
            app.tool_call_depth = 0; // Reset for next iteration

            _ = try message_renderer.redrawScreen(app);

            try app_streaming.startStreaming(app, null);
            return .iteration_complete;
        },

        .iteration_limit_reached => {
            // Max iterations reached - stop master loop
            const msg = try std.fmt.allocPrint(
                app.allocator,
                "⚠️  Reached maximum iteration limit ({d}). Stopping master loop to prevent infinite execution.",
                .{app.max_iterations},
            );
            const processed = try markdown.processMarkdown(app.allocator, msg);
            try app.messages.append(app.allocator, .{
                .role = .display_only_data,
                .content = msg,
                .processed_content = processed,
                .thinking_expanded = false,
                .timestamp = std.time.milliTimestamp(),
            });
            message_loader.onMessageAdded(app);

            // Persist error message immediately
            try app.persistMessage(app.messages.items.len - 1);

            _ = try message_renderer.redrawScreen(app);
            app.updateCursorToBottom();
            return .iteration_limit;
        },
    }
}

/// Execute the current tool and add results to message history
fn executeCurrentTool(app: *App, tool_call: ollama.ToolCall) !void {
    const call_idx = app.tool_executor.current_index;

    // Execute tool and get structured result
    var result = executeTool(app, tool_call) catch |err| blk: {
        const msg = try std.fmt.allocPrint(app.allocator, "Runtime error: {}", .{err});
        defer app.allocator.free(msg);
        break :blk try tools_module.ToolResult.err(app.allocator, .internal_error, msg, std.time.milliTimestamp());
    };
    defer result.deinit(app.allocator);

    // Create user-facing display message (FULL TRANSPARENCY)
    const display_content = try result.formatDisplay(
        app.allocator,
        tool_call.function.name,
        tool_call.function.arguments,
    );
    const display_processed = try markdown.processMarkdown(app.allocator, display_content);

    try app.messages.append(app.allocator, .{
        .role = .display_only_data,
        .content = display_content,
        .processed_content = display_processed,
        .thinking_content = null,
        .processed_thinking_content = null,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
        // Tool execution metadata for collapsible display
        .tool_call_expanded = false,
        .tool_name = try app.allocator.dupe(u8, tool_call.function.name),
        .tool_success = result.success,
        .tool_execution_time = result.metadata.execution_time_ms,
    });
    message_loader.onMessageAdded(app);

    // Persist tool execution display immediately
    try app.persistMessage(app.messages.items.len - 1);

    // Create model-facing result (JSON for LLM)
    const tool_id_copy = if (tool_call.id) |id|
        try app.allocator.dupe(u8, id)
    else
        try std.fmt.allocPrint(app.allocator, "call_{d}", .{call_idx});

    const model_result = if (result.success and result.data != null)
        try app.allocator.dupe(u8, result.data.?)
    else
        try result.toJSON(app.allocator);

    const result_processed = try markdown.processMarkdown(app.allocator, model_result);

    try app.messages.append(app.allocator, .{
        .role = .tool,
        .content = model_result,
        .processed_content = result_processed,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
        .tool_call_id = tool_id_copy,
    });
    message_loader.onMessageAdded(app);

    // Persist tool result immediately
    try app.persistMessage(app.messages.items.len - 1);

    // Redraw once for both messages (display + tool result)
    _ = try message_renderer.redrawScreen(app);
    app.updateCursorToBottom();

    // Tell executor to advance to next tool
    app.tool_executor.advanceAfterExecution();
}

/// Create denial result for a tool that was denied by user
fn createDenialResult(app: *App, tool_call: ollama.ToolCall) !void {
    const call_idx = app.tool_executor.current_index;

    // Create permission denied error result
    var result = try tools_module.ToolResult.err(
        app.allocator,
        .permission_denied,
        "User denied permission for this operation",
        std.time.milliTimestamp(),
    );
    defer result.deinit(app.allocator);

    // Create user-facing display message
    const display_content = try result.formatDisplay(
        app.allocator,
        tool_call.function.name,
        tool_call.function.arguments,
    );
    const display_processed = try markdown.processMarkdown(app.allocator, display_content);

    try app.messages.append(app.allocator, .{
        .role = .display_only_data,
        .content = display_content,
        .processed_content = display_processed,
        .thinking_content = null,
        .processed_thinking_content = null,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
        .tool_call_expanded = false,
        .tool_name = try app.allocator.dupe(u8, tool_call.function.name),
        .tool_success = false,
        .tool_execution_time = result.metadata.execution_time_ms,
    });
    message_loader.onMessageAdded(app);

    // Persist tool error display immediately
    try app.persistMessage(app.messages.items.len - 1);

    // Receipt printer mode: auto-scroll
    _ = try message_renderer.redrawScreen(app);
    app.updateCursorToBottom();

    // Create model-facing result (JSON for LLM)
    const tool_id_copy = if (tool_call.id) |id|
        try app.allocator.dupe(u8, id)
    else
        try std.fmt.allocPrint(app.allocator, "call_{d}", .{call_idx});

    const model_result = try result.toJSON(app.allocator);
    const result_processed = try markdown.processMarkdown(app.allocator, model_result);

    try app.messages.append(app.allocator, .{
        .role = .tool,
        .content = model_result,
        .processed_content = result_processed,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
        .tool_call_id = tool_id_copy,
    });
    message_loader.onMessageAdded(app);

    // Persist tool error result immediately
    try app.persistMessage(app.messages.items.len - 1);

    // Receipt printer mode: auto-scroll
    _ = try message_renderer.redrawScreen(app);
    app.updateCursorToBottom();

    // Tell executor to advance to next tool
    app.tool_executor.advanceAfterExecution();
}
