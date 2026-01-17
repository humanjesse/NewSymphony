// Agent Executor - Isolated execution engine for agents with tool calling
const std = @import("std");
const ollama = @import("ollama");
const app_module = @import("app");
const agents_module = app_module.agents_module; // Get agents from app which has it as a module
const llm_helper = @import("llm_helper");
const tools_module = @import("tools");
const context_module = @import("context");

const AgentContext = agents_module.AgentContext;
const AgentResult = agents_module.AgentResult;
const AgentStats = agents_module.AgentStats;
const AgentCapabilities = agents_module.AgentCapabilities;
const ProgressCallback = agents_module.ProgressCallback;
const ProgressUpdateType = agents_module.ProgressUpdateType;
const ToolProgressData = agents_module.ToolProgressData;
const AgentExecutorInterface = agents_module.AgentExecutorInterface;

/// Context for streaming callback
const StreamContext = struct {
    allocator: std.mem.Allocator,
    content_buffer: std.ArrayListUnmanaged(u8),
    thinking_buffer: std.ArrayListUnmanaged(u8),
    tool_calls: std.ArrayListUnmanaged(ollama.ToolCall),

    // Progress callback
    progress_callback: ?ProgressCallback,
    callback_user_data: ?*anyopaque,
};

/// Callback for streaming LLM response
fn streamCallback(
    ctx: *StreamContext,
    thinking_chunk: ?[]const u8,
    content_chunk: ?[]const u8,
    tool_calls_chunk: ?[]const ollama.ToolCall,
) void {
    // Notify progress callback
    if (ctx.progress_callback) |callback| {
        if (thinking_chunk) |chunk| {
            callback(ctx.callback_user_data, .thinking, chunk, null);
        }
        if (content_chunk) |chunk| {
            callback(ctx.callback_user_data, .content, chunk, null);
        }
    }

    // Collect thinking chunks
    if (thinking_chunk) |chunk| {
        ctx.thinking_buffer.appendSlice(ctx.allocator, chunk) catch {};
    }

    // Collect content chunks
    if (content_chunk) |chunk| {
        ctx.content_buffer.appendSlice(ctx.allocator, chunk) catch {};
    }

    // Collect tool calls
    if (tool_calls_chunk) |calls| {
        // Free the incoming chunk after processing (we take ownership from lmstudio.zig)
        defer {
            for (calls) |call| {
                if (call.id) |id| ctx.allocator.free(id);
                if (call.type) |t| ctx.allocator.free(t);
                ctx.allocator.free(call.function.name);
                ctx.allocator.free(call.function.arguments);
            }
            ctx.allocator.free(calls);
        }

        for (calls) |call| {
            // Notify progress callback about tool call
            if (ctx.progress_callback) |callback| {
                const msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "Calling {s}...",
                    .{call.function.name},
                ) catch continue;
                defer ctx.allocator.free(msg);
                callback(ctx.callback_user_data, .tool_call, msg, null);
            }

            // Deep copy the tool call
            const copied_call = ollama.ToolCall{
                .id = if (call.id) |id| ctx.allocator.dupe(u8, id) catch continue else null,
                .type = if (call.type) |t| ctx.allocator.dupe(u8, t) catch continue else null,
                .function = .{
                    .name = ctx.allocator.dupe(u8, call.function.name) catch continue,
                    .arguments = ctx.allocator.dupe(u8, call.function.arguments) catch continue,
                },
            };

            ctx.tool_calls.append(ctx.allocator, copied_call) catch {};
        }
    }
}

/// Agent executor - runs an agent's task in isolation
pub const AgentExecutor = struct {
    allocator: std.mem.Allocator,
    message_history: std.ArrayListUnmanaged(ollama.ChatMessage),
    capabilities: AgentCapabilities,

    // Statistics
    iterations_used: usize = 0,
    tool_calls_made: usize = 0,

    // Pause/resume state (for conversation mode)
    start_time: i64 = 0,
    accumulated_time_ms: i64 = 0, // Track time across pause/resume
    invocation_id: ?i64 = null,
    message_index: i64 = 0,

    // VTable for AgentExecutorInterface
    const vtable = AgentExecutorInterface.VTable{
        .deinit = vtableDeinit,
        .getMessageHistoryLen = vtableGetMessageHistoryLen,
    };

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *AgentExecutor = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn vtableGetMessageHistoryLen(ptr: *anyopaque) usize {
        const self: *AgentExecutor = @ptrCast(@alignCast(ptr));
        return self.message_history.items.len;
    }

    /// Get an interface to this executor for type-safe passing
    pub fn interface(self: *AgentExecutor) AgentExecutorInterface {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn init(allocator: std.mem.Allocator, capabilities: AgentCapabilities) AgentExecutor {
        return .{
            .allocator = allocator,
            .message_history = .{},
            .capabilities = capabilities,
        };
    }

    pub fn deinit(self: *AgentExecutor) void {
        // Free message history
        for (self.message_history.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |id| {
                self.allocator.free(id);
            }
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    if (call.id) |id| self.allocator.free(id);
                    if (call.type) |t| self.allocator.free(t);
                    self.allocator.free(call.function.name);
                    self.allocator.free(call.function.arguments);
                }
                self.allocator.free(calls);
            }
        }
        self.message_history.deinit(self.allocator);
    }

    /// Main execution loop - runs agent until completion or max iterations
    pub fn run(
        self: *AgentExecutor,
        context: AgentContext,
        system_prompt: []const u8,
        user_task: []const u8,
        available_tools: []const ollama.Tool,
        progress_callback: ?ProgressCallback,
        callback_user_data: ?*anyopaque,
    ) !AgentResult {
        // Store start time for pause/resume tracking
        self.start_time = std.time.milliTimestamp();

        // Create agent invocation record for persistence (if conversation_db is available)
        if (context.conversation_db) |db| {
            if (context.session_id) |session_id| {
                self.invocation_id = db.createAgentInvocation(
                    session_id,
                    context.system_prompt, // Use system_prompt as agent name identifier
                    context.current_task_id,
                    null, // parent_message_id - could be passed if needed
                ) catch null;
            }
        }

        // Add user task message
        try self.message_history.append(self.allocator, .{
            .role = "user",
            .content = try self.allocator.dupe(u8, user_task),
        });

        // Persist user message
        if (context.conversation_db) |db| {
            if (self.invocation_id) |inv_id| {
                _ = db.saveAgentMessage(inv_id, self.message_index, "user", user_task, null, null, null, null) catch {};
                self.message_index += 1;
            }
        }

        // Filter tools based on capabilities
        const allowed_tools = try self.filterAllowedTools(available_tools);
        defer self.allocator.free(allowed_tools);

        // Execute the iteration loop
        return try self.executeIterationLoop(context, system_prompt, allowed_tools, progress_callback, callback_user_data);
    }

    /// Resume execution after user provided input (for conversation mode)
    /// Call this when AgentResult.status == .needs_input and you have the user's response
    pub fn resumeWithUserInput(
        self: *AgentExecutor,
        context: AgentContext,
        system_prompt: []const u8,
        user_response: []const u8,
        available_tools: []const ollama.Tool,
        progress_callback: ?ProgressCallback,
        callback_user_data: ?*anyopaque,
    ) !AgentResult {
        // Reset start time for this resume session
        self.start_time = std.time.milliTimestamp();

        // Add the user's response to message history
        try self.message_history.append(self.allocator, .{
            .role = "user",
            .content = try self.allocator.dupe(u8, user_response),
        });

        // Persist user message
        if (context.conversation_db) |db| {
            if (self.invocation_id) |inv_id| {
                _ = db.saveAgentMessage(inv_id, self.message_index, "user", user_response, null, null, null, null) catch {};
                self.message_index += 1;
            }
        }

        // Filter tools based on capabilities
        const allowed_tools = try self.filterAllowedTools(available_tools);
        defer self.allocator.free(allowed_tools);

        // Execute the iteration loop
        return try self.executeIterationLoop(context, system_prompt, allowed_tools, progress_callback, callback_user_data);
    }

    /// Private: shared iteration loop for run() and resumeWithUserInput()
    fn executeIterationLoop(
        self: *AgentExecutor,
        context: AgentContext,
        system_prompt: []const u8,
        allowed_tools: []const ollama.Tool,
        progress_callback: ?ProgressCallback,
        callback_user_data: ?*anyopaque,
    ) !AgentResult {
        // Track thinking content across iterations (will contain final thinking)
        var final_thinking: ?[]const u8 = null;
        defer if (final_thinking) |t| self.allocator.free(t);

        // Main iteration loop (max_iterations: 0 = infinite)
        while (self.capabilities.max_iterations == 0 or
            self.iterations_used < self.capabilities.max_iterations)
        {
            self.iterations_used += 1;

            // Notify progress callback
            if (progress_callback) |callback| {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Iteration {d}/{d}",
                    .{ self.iterations_used, self.capabilities.max_iterations },
                );
                defer self.allocator.free(msg);
                callback(callback_user_data, .iteration, msg, null);
            }

            // Prepare streaming context
            var stream_ctx = StreamContext{
                .allocator = self.allocator,
                .content_buffer = .{},
                .thinking_buffer = .{},
                .tool_calls = .{},
                .progress_callback = progress_callback,
                .callback_user_data = callback_user_data,
            };
            defer stream_ctx.content_buffer.deinit(self.allocator);
            // Note: thinking_buffer is extracted before defer, so don't deinit here
            // Clean up tool_calls if they weren't transferred (error case)
            defer {
                for (stream_ctx.tool_calls.items) |call| {
                    if (call.id) |id| self.allocator.free(id);
                    if (call.type) |t| self.allocator.free(t);
                    self.allocator.free(call.function.name);
                    self.allocator.free(call.function.arguments);
                }
                stream_ctx.tool_calls.deinit(self.allocator);
            }

            // Call LLM
            const model = context.capabilities.model_override orelse context.config.model;
            const request = llm_helper.LLMRequest{
                .model = model,
                .messages = self.message_history.items,
                .system_prompt = system_prompt,
                .tools = if (allowed_tools.len > 0) allowed_tools else null,
                .temperature = self.capabilities.temperature,
                .num_ctx = self.capabilities.num_ctx,
                .num_predict = self.capabilities.num_predict,
                .think = self.capabilities.enable_thinking,
                .format = self.capabilities.format,
            };

            llm_helper.chatStream(
                context.llm_provider,
                request,
                self.allocator,
                &stream_ctx,
                streamCallback,
            ) catch |err| {
                const end_time = std.time.milliTimestamp();
                const stats = AgentStats{
                    .iterations_used = self.iterations_used,
                    .tool_calls_made = self.tool_calls_made,
                    .execution_time_ms = end_time - self.start_time + self.accumulated_time_ms,
                };
                const error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "LLM call failed: {}",
                    .{err},
                );
                defer self.allocator.free(error_msg);

                // Complete the invocation record with error status
                if (context.conversation_db) |db| {
                    if (self.invocation_id) |inv_id| {
                        db.completeAgentInvocation(inv_id, "failed", error_msg, @intCast(self.tool_calls_made), @intCast(self.iterations_used)) catch {};
                    }
                }

                return try AgentResult.err(self.allocator, error_msg, stats);
            };

            // Get response content and thinking
            const response_content = try stream_ctx.content_buffer.toOwnedSlice(self.allocator);
            defer self.allocator.free(response_content);

            // Update final_thinking with latest iteration's thinking
            // (Free previous thinking if it exists)
            if (final_thinking) |old_thinking| {
                self.allocator.free(old_thinking);
            }
            final_thinking = if (stream_ctx.thinking_buffer.items.len > 0)
                try stream_ctx.thinking_buffer.toOwnedSlice(self.allocator)
            else
                null;

            // Add assistant message to history
            try self.message_history.append(self.allocator, .{
                .role = "assistant",
                .content = try self.allocator.dupe(u8, response_content),
                .tool_calls = if (stream_ctx.tool_calls.items.len > 0)
                    try stream_ctx.tool_calls.toOwnedSlice(self.allocator)
                else
                    null,
            });

            // Persist assistant message
            if (context.conversation_db) |db| {
                if (self.invocation_id) |inv_id| {
                    _ = db.saveAgentMessage(inv_id, self.message_index, "assistant", response_content, final_thinking, null, null, null) catch {};
                    self.message_index += 1;
                }
            }

            // Check if we have tool calls to execute
            const last_msg = self.message_history.items[self.message_history.items.len - 1];
            if (last_msg.tool_calls) |tool_calls| {
                // Execute tool calls
                for (tool_calls) |tool_call| {
                    // Notify tool_start
                    if (progress_callback) |callback| {
                        callback(callback_user_data, .tool_start, tool_call.function.name, null);
                    }

                    const tool_start_time = std.time.milliTimestamp();
                    const tool_result = try self.executeTool(tool_call, context);
                    const exec_time = std.time.milliTimestamp() - tool_start_time;
                    defer self.allocator.free(tool_result);

                    // Notify tool_complete with structured data
                    if (progress_callback) |callback| {
                        const success = !std.mem.startsWith(u8, tool_result, "Error:");
                        const tool_data = ToolProgressData{
                            .name = tool_call.function.name,
                            .success = success,
                            .execution_time_ms = exec_time,
                        };
                        callback(callback_user_data, .tool_complete, tool_call.function.name, &tool_data);
                    }

                    // Add tool result to message history
                    const tool_call_id = tool_call.id orelse "unknown";
                    try self.message_history.append(self.allocator, .{
                        .role = "tool",
                        .content = try self.allocator.dupe(u8, tool_result),
                        .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
                    });

                    // Persist tool message
                    if (context.conversation_db) |db| {
                        if (self.invocation_id) |inv_id| {
                            _ = db.saveAgentMessage(inv_id, self.message_index, "tool", tool_result, null, tool_call_id, tool_call.function.name, true) catch {};
                            self.message_index += 1;
                        }
                    }

                    self.tool_calls_made += 1;
                }
                // Continue to next iteration to process tool results
                continue;
            }

            // No tool calls - check if conversation mode
            const end_time = std.time.milliTimestamp();
            const stats = AgentStats{
                .iterations_used = self.iterations_used,
                .tool_calls_made = self.tool_calls_made,
                .execution_time_ms = end_time - self.start_time + self.accumulated_time_ms,
            };

            if (self.capabilities.conversation_mode) {
                // Conversation mode: agent responded, wait for user input
                // Update accumulated time for next resume
                self.accumulated_time_ms += end_time - self.start_time;

                var result = try AgentResult.ok(self.allocator, response_content, stats, final_thinking);
                result.status = .needs_input;
                return result;
            }

            // Non-conversation mode: we're done!
            // Notify completion
            if (progress_callback) |callback| {
                callback(callback_user_data, .complete, "Agent completed", null);
            }

            // Complete the invocation record
            if (context.conversation_db) |db| {
                if (self.invocation_id) |inv_id| {
                    db.completeAgentInvocation(inv_id, "completed", response_content, @intCast(self.tool_calls_made), @intCast(self.iterations_used)) catch {};
                }
            }

            return try AgentResult.ok(self.allocator, response_content, stats, final_thinking);
        }

        // Max iterations reached
        const end_time = std.time.milliTimestamp();
        const stats = AgentStats{
            .iterations_used = self.iterations_used,
            .tool_calls_made = self.tool_calls_made,
            .execution_time_ms = end_time - self.start_time + self.accumulated_time_ms,
        };

        // Complete the invocation record with error status
        if (context.conversation_db) |db| {
            if (self.invocation_id) |inv_id| {
                db.completeAgentInvocation(inv_id, "failed", "Max iterations reached without completion", @intCast(self.tool_calls_made), @intCast(self.iterations_used)) catch {};
            }
        }

        return try AgentResult.err(
            self.allocator,
            "Max iterations reached without completion",
            stats,
        );
    }

    /// Filter tools based on agent capabilities
    fn filterAllowedTools(self: *AgentExecutor, all_tools: []const ollama.Tool) ![]const ollama.Tool {
        if (self.capabilities.allowed_tools.len == 0) {
            // No tools allowed
            return &.{};
        }

        var filtered = std.ArrayListUnmanaged(ollama.Tool){};
        defer filtered.deinit(self.allocator);

        for (all_tools) |tool| {
            for (self.capabilities.allowed_tools) |allowed_name| {
                if (std.mem.eql(u8, tool.function.name, allowed_name)) {
                    try filtered.append(self.allocator, tool);
                    break;
                }
            }
        }

        return try filtered.toOwnedSlice(self.allocator);
    }

    /// Execute a single tool call (agents bypass permission system - they're trusted)
    fn executeTool(
        self: *AgentExecutor,
        tool_call: ollama.ToolCall,
        agent_context: AgentContext,
    ) ![]const u8 {
        // Check if tool is allowed
        var is_allowed = false;
        for (self.capabilities.allowed_tools) |allowed_name| {
            if (std.mem.eql(u8, tool_call.function.name, allowed_name)) {
                is_allowed = true;
                break;
            }
        }

        if (!is_allowed) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Error: Tool '{s}' not allowed for this agent",
                .{tool_call.function.name},
            );
        }

        // Build AppContext from AgentContext
        // Pass through all context fields so agents can use any tool
        var app_context = context_module.AppContext{
            .allocator = self.allocator,
            .config = agent_context.config,
            .state = agent_context.state,
            .llm_provider = agent_context.llm_provider,
            .vector_store = agent_context.vector_store,
            .embedder = agent_context.embedder,
            .recent_messages = agent_context.recent_messages,
            .task_store = agent_context.task_store,
            .task_db = agent_context.task_db,
            .git_sync = agent_context.git_sync,
            .agent_registry = agent_context.agent_registry,
        };

        // Execute tool (look up in tools module)
        var tool_result = tools_module.executeToolCall(
            self.allocator,
            tool_call,
            &app_context,
        ) catch |err| {
            return try std.fmt.allocPrint(
                self.allocator,
                "Error executing tool: {}",
                .{err},
            );
        };
        defer tool_result.deinit(self.allocator);

        // Format result as string (data is duped, original freed by defer)
        if (tool_result.success) {
            if (tool_result.data) |data| {
                return try self.allocator.dupe(u8, data);
            } else {
                return try self.allocator.dupe(u8, "Success (no data)");
            }
        } else {
            const error_msg = tool_result.error_message orelse "Unknown error";
            return try std.fmt.allocPrint(
                self.allocator,
                "Error: {s}",
                .{error_msg},
            );
        }
    }
};
