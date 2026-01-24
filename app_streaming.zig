// Streaming module - handles LLM streaming thread and chunk processing
const std = @import("std");
const mem = std.mem;
const ollama = @import("ollama");
const markdown = @import("markdown");
const llm_provider_module = @import("llm_provider");
const message_renderer = @import("message_renderer");
const message_loader = @import("message_loader");
const types = @import("types");

// Forward declare App type to avoid circular dependency
const App = @import("app.zig").App;

/// Thread function context for background streaming
pub const StreamThreadContext = struct {
    allocator: mem.Allocator,
    app: *App,
    llm_provider: *llm_provider_module.LLMProvider,
    model: []const u8,
    messages: []ollama.ChatMessage,
    format: ?[]const u8,
    tools: []const ollama.Tool,
    keep_alive: []const u8,
    num_ctx: usize,
    num_predict: isize,
};

/// Result of processing stream chunks
pub const ChunkProcessResult = struct {
    streaming_complete: bool,
    has_pending_tool_calls: bool,
    needs_redraw: bool,
};

/// Background thread function for streaming LLM responses
pub fn streamingThreadFn(ctx: *StreamThreadContext) void {
    // Callback that adds chunks to the queue
    const ChunkCallback = struct {
        fn callback(chunk_ctx: *StreamThreadContext, thinking_chunk: ?[]const u8, content_chunk: ?[]const u8, tool_calls_chunk: ?[]const ollama.ToolCall) void {
            chunk_ctx.app.stream_mutex.lock();
            defer chunk_ctx.app.stream_mutex.unlock();

            // Free tool_calls_chunk after processing (we take ownership from ollama.zig)
            defer if (tool_calls_chunk) |calls| {
                for (calls) |call| {
                    if (call.id) |id| chunk_ctx.allocator.free(id);
                    if (call.type) |t| chunk_ctx.allocator.free(t);
                    chunk_ctx.allocator.free(call.function.name);
                    chunk_ctx.allocator.free(call.function.arguments);
                }
                chunk_ctx.allocator.free(calls);
            };

            // Create a chunk and add to queue
            const chunk = types.StreamChunk{
                .thinking = if (thinking_chunk) |t| chunk_ctx.allocator.dupe(u8, t) catch null else null,
                .content = if (content_chunk) |c| chunk_ctx.allocator.dupe(u8, c) catch null else null,
                .done = false,
            };
            chunk_ctx.app.stream_chunks.append(chunk_ctx.allocator, chunk) catch return;

            // Store tool calls for execution after streaming completes
            if (tool_calls_chunk) |calls| {
                // Duplicate the tool calls to keep them after streaming
                const owned_calls = chunk_ctx.allocator.alloc(ollama.ToolCall, calls.len) catch return;
                for (calls, 0..) |call, i| {
                    // Generate ID if not provided by model
                    const call_id = if (call.id) |id|
                        chunk_ctx.allocator.dupe(u8, id) catch return
                    else
                        std.fmt.allocPrint(chunk_ctx.allocator, "call_{d}", .{i}) catch return;

                    // Use "function" as default type if not provided
                    const call_type = if (call.type) |t|
                        chunk_ctx.allocator.dupe(u8, t) catch return
                    else
                        chunk_ctx.allocator.dupe(u8, "function") catch return;

                    owned_calls[i] = ollama.ToolCall{
                        .id = call_id,
                        .type = call_type,
                        .function = .{
                            .name = chunk_ctx.allocator.dupe(u8, call.function.name) catch return,
                            .arguments = chunk_ctx.allocator.dupe(u8, call.function.arguments) catch return,
                        },
                    };
                }
                chunk_ctx.app.pending_tool_calls = owned_calls;
            }
        }
    };

    // Get provider capabilities to check what's supported
    const caps = ctx.llm_provider.getCapabilities();

    // Only enable thinking if both config and provider support it
    const enable_thinking = ctx.app.config.enable_thinking and caps.supports_thinking;

    // Only pass keep_alive if provider supports it
    const keep_alive = if (caps.supports_keep_alive) ctx.keep_alive else null;

    // Run the streaming with retry logic for stale connections
    ctx.llm_provider.chatStream(
        ctx.model,
        ctx.messages,
        enable_thinking, // Capability-aware thinking mode
        ctx.format,
        if (ctx.tools.len > 0) ctx.tools else null, // Pass tools to model
        keep_alive, // Capability-aware keep_alive
        ctx.num_ctx,
        ctx.num_predict,
        null, // temperature - use model default for main chat
        null, // repeat_penalty - use model default for main chat
        ctx,
        ChunkCallback.callback,
    ) catch |err| {
        // Handle stale connection errors with retry
        if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
            // Send retry message to user
            ctx.app.stream_mutex.lock();
            const retry_msg = std.fmt.allocPrint(
                ctx.allocator,
                "Connection failed: {s} - Retrying...",
                .{@errorName(err)},
            ) catch "Connection failed - Retrying...";
            const retry_chunk = types.StreamChunk{ .thinking = null, .content = retry_msg, .done = false };
            ctx.app.stream_chunks.append(ctx.allocator, retry_chunk) catch {};
            ctx.app.stream_mutex.unlock();

            // Small delay before retry
            std.Thread.sleep(100 * std.time.ns_per_ms);

            // Retry the request (reuse capability checks from above)
            ctx.llm_provider.chatStream(
                ctx.model,
                ctx.messages,
                enable_thinking, // Use capability-aware value
                ctx.format,
                if (ctx.tools.len > 0) ctx.tools else null,
                keep_alive, // Use capability-aware value
                ctx.num_ctx,
                ctx.num_predict,
                null, // temperature - use model default for main chat
                null, // repeat_penalty - use model default for main chat
                ctx,
                ChunkCallback.callback,
            ) catch |retry_err| {
                // Second failure - report error to user
                ctx.app.stream_mutex.lock();
                const error_msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "Failed to connect to Ollama: {s}",
                    .{@errorName(retry_err)},
                ) catch "Failed to connect to Ollama";
                const error_chunk = types.StreamChunk{ .thinking = null, .content = error_msg, .done = false };
                ctx.app.stream_chunks.append(ctx.allocator, error_chunk) catch {};
                ctx.app.stream_mutex.unlock();
            };
        } else {
            // Other errors - report directly to user
            ctx.app.stream_mutex.lock();
            const error_msg = std.fmt.allocPrint(
                ctx.allocator,
                "Connection error: {s}",
                .{@errorName(err)},
            ) catch "Connection error occurred";
            const error_chunk = types.StreamChunk{ .thinking = null, .content = error_msg, .done = false };
            ctx.app.stream_chunks.append(ctx.allocator, error_chunk) catch {};
            ctx.app.stream_mutex.unlock();
        }
    };

    // ALWAYS add a "done" chunk, even if chatStream failed
    // This ensures streaming_active gets set to false
    ctx.app.stream_mutex.lock();
    defer ctx.app.stream_mutex.unlock();
    const done_chunk = types.StreamChunk{ .thinking = null, .content = null, .done = true };
    ctx.app.stream_chunks.append(ctx.allocator, done_chunk) catch return;
}

/// Start streaming with current message history (non-blocking)
pub fn startStreaming(app: *App, format: ?[]const u8) !void {
    // Set streaming flag FIRST - before any redraws
    // This ensures the status bar shows "AI is responding..." immediately
    app.streaming_active = true;

    // Copy messages to ollama_messages
    var ollama_messages = std.ArrayListUnmanaged(ollama.ChatMessage){};
    defer ollama_messages.deinit(app.allocator);

    for (app.messages.items) |msg| {
        // Skip display_only_data messages - they're UI-only notifications
        if (msg.role == .display_only_data) continue;

        // Skip subagent messages - they have their own isolated context
        if (msg.agent_source != null) continue;

        const role_str = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
            .system => "system",
            .tool => "tool",
            .display_only_data => unreachable, // Already filtered above
        };
        try ollama_messages.append(app.allocator, .{
            .role = role_str,
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_calls = msg.tool_calls,
        });
    }

    // DEBUG: Print what we're sending to the API
    if (std.posix.getenv("DEBUG_TOOLS")) |_| {
        std.debug.print("\n=== DEBUG: Sending {d} messages to API ===\n", .{ollama_messages.items.len});
        for (ollama_messages.items, 0..) |msg, i| {
            std.debug.print("[{d}] role={s}", .{ i, msg.role });
            if (msg.tool_calls) |_| std.debug.print(" [HAS_TOOL_CALLS]", .{});
            if (msg.tool_call_id) |id| std.debug.print(" [tool_call_id={s}]", .{id});
            std.debug.print("\n", .{});

            const preview_len = @min(msg.content.len, 80);
            std.debug.print("    content: {s}{s}\n", .{
                msg.content[0..preview_len],
                if (msg.content.len > 80) "..." else "",
            });
        }
        std.debug.print("=== END DEBUG ===\n\n", .{});
    }

    // Create placeholder for assistant response (empty initially)
    const assistant_content = try app.allocator.dupe(u8, "");
    const assistant_processed = try markdown.processMarkdown(app.allocator, assistant_content);
    try app.messages.append(app.allocator, .{
        .role = .assistant,
        .content = assistant_content,
        .processed_content = assistant_processed,
        .thinking_content = null,
        .processed_thinking_content = null,
        .thinking_expanded = true,
        .timestamp = std.time.milliTimestamp(),
    });
    message_loader.onMessageAdded(app);

    // Redraw to show empty placeholder (receipt printer mode)
    _ = try message_renderer.redrawScreen(app);
    app.updateCursorToBottom();

    // Clear any pending stream chunks from previous sessions (race condition fix)
    // This prevents old "done" chunks from clearing state for the new session
    {
        app.stream_mutex.lock();
        defer app.stream_mutex.unlock();
        for (app.stream_chunks.items) |chunk| {
            if (chunk.thinking) |t| app.allocator.free(t);
            if (chunk.content) |c| app.allocator.free(c);
        }
        app.stream_chunks.clearRetainingCapacity();
    }

    // Set streaming message ID and protection (matching agent pattern)
    // Must use absolute index for virtualization compatibility
    const local_idx = app.messages.items.len - 1;
    const abs_idx = app.virtualization.absoluteIndex(local_idx);
    app.streaming_message_idx = abs_idx;
    message_loader.setStreamingProtection(app, abs_idx);

    // Assign stable message ID for streaming target (survives virtualization shifts)
    const message_id = app.assignMessageId(&app.messages.items[local_idx]);
    app.streaming_message_id = message_id;

    // Prepare thread context
    const messages_slice = try ollama_messages.toOwnedSlice(app.allocator);

    const thread_ctx = try app.allocator.create(StreamThreadContext);
    thread_ctx.* = .{
        .allocator = app.allocator,
        .app = app,
        .llm_provider = &app.llm_provider,
        .model = app.config.model,
        .messages = messages_slice,
        .format = format,
        .tools = app.tools,
        .keep_alive = app.config.model_keep_alive,
        .num_ctx = app.config.num_ctx,
        .num_predict = app.config.num_predict,
    };

    // Start streaming in background thread
    app.stream_thread_ctx = thread_ctx;
    app.stream_thread = try std.Thread.spawn(.{}, streamingThreadFn, .{thread_ctx});
}

/// Process pending stream chunks and update app state
/// Returns information about what happened for the caller to act on
pub fn processStreamChunks(
    app: *App,
    thinking_accumulator: *std.ArrayListUnmanaged(u8),
    content_accumulator: *std.ArrayListUnmanaged(u8),
) !ChunkProcessResult {
    var result = ChunkProcessResult{
        .streaming_complete = false,
        .has_pending_tool_calls = false,
        .needs_redraw = false,
    };

    app.stream_mutex.lock();

    var chunks_were_processed = false;

    // Process all pending chunks
    for (app.stream_chunks.items) |chunk| {
        chunks_were_processed = true;
        if (chunk.done) {
            // Streaming complete - clean up
            app.streaming_active = false;
            app.scroll.enableAutoScroll();
            result.streaming_complete = true;

            // Find target message for final processing
            const target_idx: ?usize = blk: {
                if (app.streaming_message_id) |msg_id| {
                    break :blk app.findMessageById(msg_id);
                }
                if (app.streaming_message_idx) |abs_idx| {
                    break :blk app.virtualization.localIndex(abs_idx);
                }
                break :blk if (app.messages.items.len > 0) app.messages.items.len - 1 else null;
            };

            // Final markdown processing (bypasses throttle to ensure complete rendering)
            if (target_idx) |idx| {
                var final_message = &app.messages.items[idx];
                if (final_message.role == .assistant) {
                    // Final thinking content processing
                    if (thinking_accumulator.items.len > 0) {
                        if (final_message.thinking_content) |old| app.allocator.free(old);
                        final_message.thinking_content = try app.allocator.dupe(u8, thinking_accumulator.items);
                        if (final_message.processed_thinking_content) |*old_processed| {
                            for (old_processed.items) |*item| item.deinit(app.allocator);
                            old_processed.deinit(app.allocator);
                        }
                        final_message.processed_thinking_content = try markdown.processMarkdown(app.allocator, final_message.thinking_content.?);
                    }
                    // Final content processing
                    if (content_accumulator.items.len > 0) {
                        app.allocator.free(final_message.content);
                        final_message.content = try app.allocator.dupe(u8, content_accumulator.items);
                        for (final_message.processed_content.items) |*item| item.deinit(app.allocator);
                        final_message.processed_content.deinit(app.allocator);
                        final_message.processed_content = try markdown.processMarkdown(app.allocator, final_message.content);
                    }
                }
                // Collapse thinking when done
                final_message.thinking_expanded = false;
            }

            thinking_accumulator.clearRetainingCapacity();
            content_accumulator.clearRetainingCapacity();

            // Clear the streaming message index and ID
            app.streaming_message_idx = null;
            app.streaming_message_id = null;

            // Clear streaming protection (Phase 3: Virtualization)
            message_loader.clearStreamingProtection(app);

            // Wait for thread to finish and clean up context
            if (app.stream_thread) |thread| {
                app.stream_mutex.unlock();
                thread.join();
                app.stream_mutex.lock();
                app.stream_thread = null;

                // Free thread context and its data
                if (app.stream_thread_ctx) |ctx| {
                    app.allocator.free(ctx.messages);
                    app.allocator.destroy(ctx);
                    app.stream_thread_ctx = null;
                }
            }

            // Check if model requested tool calls
            const tool_calls_to_execute = app.pending_tool_calls;
            app.pending_tool_calls = null; // Clear pending calls

            if (tool_calls_to_execute) |tool_calls| {
                // Check recursion depth
                if (app.tool_call_depth >= app.max_tool_depth) {
                    // Too many recursive tool calls - show error and stop
                    app.stream_mutex.unlock();

                    const error_msg = try app.allocator.dupe(u8, "Error: Maximum tool call depth reached. Stopping to prevent infinite loop.");
                    const error_processed = try markdown.processMarkdown(app.allocator, error_msg);
                    try app.messages.append(app.allocator, .{
                        .role = .display_only_data,
                        .content = error_msg,
                        .processed_content = error_processed,
                        .thinking_expanded = false,
                        .timestamp = std.time.milliTimestamp(),
                    });
                    message_loader.onMessageAdded(app);

                    // Persist streaming error immediately
                    try app.persistMessage(app.messages.items.len - 1);

                    // Clean up tool calls
                    for (tool_calls) |call| {
                        if (call.id) |id| app.allocator.free(id);
                        if (call.type) |call_type| app.allocator.free(call_type);
                        app.allocator.free(call.function.name);
                        app.allocator.free(call.function.arguments);
                    }
                    app.allocator.free(tool_calls);

                    app.stream_mutex.lock();
                } else {
                    app.stream_mutex.unlock();

                    // Increment depth
                    app.tool_call_depth += 1;

                    // Attach tool calls to the last assistant message
                    if (app.messages.items.len > 0) {
                        var last_message = &app.messages.items[app.messages.items.len - 1];
                        if (last_message.role == .assistant) {
                            last_message.tool_calls = tool_calls;
                        }
                    }

                    // Persist assistant message with tool_calls attached
                    try app.persistMessage(app.messages.items.len - 1);

                    // Update display to show tool call
                    _ = try message_renderer.redrawScreen(app);
                    app.updateCursorToBottom();

                    // Signal that we have pending tool calls
                    result.has_pending_tool_calls = true;

                    // Store tool calls for caller to start execution
                    app.pending_tool_calls = tool_calls;

                    // Re-lock mutex before continuing
                    app.stream_mutex.lock();
                }
            } else {
                // No tool calls - response is complete
                // Persist completed assistant message
                try app.persistMessage(app.messages.items.len - 1);
            }
        } else {
            // Accumulate chunks
            if (chunk.thinking) |t| {
                try thinking_accumulator.appendSlice(app.allocator, t);
            }
            if (chunk.content) |c| {
                try content_accumulator.appendSlice(app.allocator, c);
            }

            // Update the target message using stable message ID (survives virtualization shifts)
            // Fall back to index-based lookup if no ID set (shouldn't happen)
            const local_target_idx: ?usize = blk: {
                // Primary: Use stable message ID to find target (survives virtualization)
                if (app.streaming_message_id) |msg_id| {
                    if (app.findMessageById(msg_id)) |idx| {
                        break :blk idx;
                    }
                    // Message with this ID not found (unloaded) - skip chunk
                    break :blk null;
                }
                // Fallback: Use absolute index if no ID set
                if (app.streaming_message_idx) |abs_idx| {
                    break :blk app.virtualization.localIndex(abs_idx);
                }
                // No streaming target set - skip this chunk (orphaned during transition)
                break :blk null;
            };
            if (local_target_idx) |msg_idx| {
                var last_message = &app.messages.items[msg_idx];

                // Only update assistant messages - skip display_only_data, tool, user, etc.
                // This can happen during agent transitions if chunks arrive out of order
                // Note: Don't free here - the end-of-loop cleanup handles freeing
                if (last_message.role != .assistant) {
                    continue;
                }

                // Throttle markdown reprocessing (100ms interval during streaming)
                const MARKDOWN_THROTTLE_MS = 100;
                const now = std.time.milliTimestamp();
                const should_reprocess_markdown = (now - app.last_markdown_process_time) >= MARKDOWN_THROTTLE_MS;

                // Update thinking content if we have any
                if (thinking_accumulator.items.len > 0) {
                    if (last_message.thinking_content) |old_thinking| {
                        app.allocator.free(old_thinking);
                    }
                    last_message.thinking_content = try app.allocator.dupe(u8, thinking_accumulator.items);

                    // Only reprocess markdown if throttle allows
                    if (should_reprocess_markdown) {
                        if (last_message.processed_thinking_content) |*old_processed| {
                            for (old_processed.items) |*item| {
                                item.deinit(app.allocator);
                            }
                            old_processed.deinit(app.allocator);
                        }
                        last_message.processed_thinking_content = try markdown.processMarkdown(app.allocator, last_message.thinking_content.?);
                    }
                }

                // Update main content (always update raw content, throttle markdown)
                app.allocator.free(last_message.content);
                last_message.content = try app.allocator.dupe(u8, content_accumulator.items);

                // Only reprocess markdown if throttle allows
                if (should_reprocess_markdown) {
                    for (last_message.processed_content.items) |*item| {
                        item.deinit(app.allocator);
                    }
                    last_message.processed_content.deinit(app.allocator);
                    last_message.processed_content = try markdown.processMarkdown(app.allocator, last_message.content);
                    app.last_markdown_process_time = now;
                }

                // DEBUG: Check content encoding
                if (std.posix.getenv("DEBUG_LMSTUDIO") != null and last_message.content.len > 0) {
                    const preview_len = @min(100, last_message.content.len);
                    std.debug.print("\nDEBUG APP: Raw content ({d} bytes): {s}\n", .{ last_message.content.len, last_message.content[0..preview_len] });

                    // Show hex dump of raw content
                    const hex_len = @min(100, last_message.content.len);
                    std.debug.print("DEBUG APP: Raw content hex: ", .{});
                    for (last_message.content[0..hex_len]) |byte| {
                        std.debug.print("{x:0>2} ", .{byte});
                    }
                    std.debug.print("\n", .{});

                    // Check for ANSI escape codes
                    if (std.mem.indexOf(u8, last_message.content, "\x1b")) |idx| {
                        std.debug.print("WARNING: Found ANSI escape code at position {d}!\n", .{idx});
                    }

                    // Check for high bytes (> 127) that might be problematic
                    for (last_message.content[0..@min(100, last_message.content.len)], 0..) |byte, i| {
                        if (byte >= 128) {
                            std.debug.print("DEBUG: High byte 0x{x:0>2} at position {d}\n", .{ byte, i });
                        }
                    }
                }

                // DEBUG: Check if markdown processing worked
                if (std.posix.getenv("DEBUG_LMSTUDIO") != null) {
                    std.debug.print("DEBUG APP: Processed markdown - got {d} items\n", .{last_message.processed_content.items.len});
                    if (last_message.processed_content.items.len > 0) {
                        std.debug.print("DEBUG APP: First item type: {s}\n", .{@tagName(last_message.processed_content.items[0].tag)});

                        // Check what's in the styled_text
                        if (last_message.processed_content.items[0].tag == .styled_text) {
                            const styled = last_message.processed_content.items[0].payload.styled_text;
                            if (styled.len < 100) {
                                std.debug.print("DEBUG APP: Styled text content: {s}\n", .{styled});
                                // Show hex of first 50 bytes
                                const hex_len = @min(50, styled.len);
                                std.debug.print("DEBUG APP: Hex: ", .{});
                                for (styled[0..hex_len]) |byte| {
                                    std.debug.print("{x:0>2} ", .{byte});
                                }
                                std.debug.print("\n", .{});
                            }
                        }
                    }
                }
            } // msg_idx
        }

        // Free the chunk's data
        if (chunk.thinking) |t| app.allocator.free(t);
        if (chunk.content) |c| app.allocator.free(c);
    }

    // Clear processed chunks
    app.stream_chunks.clearRetainingCapacity();
    app.stream_mutex.unlock();

    // Set needs_redraw flag if chunks were processed
    if (chunks_were_processed) {
        result.needs_redraw = true;
    }

    return result;
}
