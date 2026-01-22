// OpenRouter API client (OpenAI-compatible with Bearer auth)
// Based on lmstudio.zig but adapted for cloud-hosted OpenRouter API
const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const ollama = @import("ollama"); // Re-use common types

// OpenAI-compatible streaming response format
const OpenAIStreamChunk = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    created: ?i64 = null,
    model: ?[]const u8 = null,
    choices: ?[]struct {
        index: ?i32 = null,
        delta: ?struct {
            role: ?[]const u8 = null,
            content: ?[]const u8 = null,
            tool_calls: ?[]struct {
                index: ?i32 = null,
                id: ?[]const u8 = null,
                type: ?[]const u8 = null,
                function: ?struct {
                    name: ?[]const u8 = null,
                    arguments: ?[]const u8 = null,
                } = null,
            } = null,
        } = null,
        finish_reason: ?[]const u8 = null,
    } = null,
    usage: ?struct {
        prompt_tokens: ?i32 = null,
        completion_tokens: ?i32 = null,
        total_tokens: ?i32 = null,
    } = null,
};

// OpenAI error response format
const OpenAIErrorResponse = struct {
    @"error": struct {
        message: []const u8,
        type: []const u8,
        code: ?[]const u8 = null,
    },
};

/// OpenRouter Chat Client (OpenAI-compatible with Bearer token auth)
pub const OpenRouterClient = struct {
    allocator: mem.Allocator,
    client: http.Client,
    base_url: []const u8,
    api_key: []const u8,

    pub fn init(allocator: mem.Allocator, base_url: []const u8, api_key: []const u8) OpenRouterClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .base_url = base_url,
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *OpenRouterClient) void {
        self.client.deinit();
    }

    /// Streaming chat with callback for each chunk
    /// Adapts OpenAI format to Ollama-compatible callback interface
    pub fn chatStream(
        self: *OpenRouterClient,
        model: []const u8,
        messages: []const ollama.ChatMessage,
        format: ?[]const u8,
        tools: ?[]const ollama.Tool,
        num_predict: ?isize,
        temperature: ?f32,
        context: anytype,
        callback: fn (
            ctx: @TypeOf(context),
            thinking_chunk: ?[]const u8,
            content_chunk: ?[]const u8,
            tool_calls_chunk: ?[]const ollama.ToolCall,
        ) void,
    ) !void {
        // Build JSON payload manually for performance
        var payload_list = std.ArrayListUnmanaged(u8){};
        defer payload_list.deinit(self.allocator);

        try payload_list.appendSlice(self.allocator, "{\"model\":\"");
        try payload_list.appendSlice(self.allocator, model);
        try payload_list.appendSlice(self.allocator, "\",\"messages\":[");

        // Add messages
        for (messages, 0..) |msg, i| {
            if (i > 0) try payload_list.append(self.allocator, ',');
            try payload_list.appendSlice(self.allocator, "{\"role\":\"");
            try payload_list.appendSlice(self.allocator, msg.role);

            // For assistant messages with tool_calls and no content, use null
            // OpenRouter/Anthropic rejects empty string content with tool_calls
            const is_assistant = std.mem.eql(u8, msg.role, "assistant");
            const has_tool_calls = msg.tool_calls != null and msg.tool_calls.?.len > 0;
            const has_empty_content = msg.content.len == 0;

            if (is_assistant and has_tool_calls and has_empty_content) {
                try payload_list.appendSlice(self.allocator, "\",\"content\":null");
            } else {
                try payload_list.appendSlice(self.allocator, "\",\"content\":\"");

                // Escape message content
                for (msg.content) |c| {
                    if (c == '"') {
                        try payload_list.appendSlice(self.allocator, "\\\"");
                    } else if (c == '\\') {
                        try payload_list.appendSlice(self.allocator, "\\\\");
                    } else if (c == '\n') {
                        try payload_list.appendSlice(self.allocator, "\\n");
                    } else if (c == '\r') {
                        try payload_list.appendSlice(self.allocator, "\\r");
                    } else if (c == '\t') {
                        try payload_list.appendSlice(self.allocator, "\\t");
                    } else {
                        try payload_list.append(self.allocator, c);
                    }
                }
                try payload_list.append(self.allocator, '"');
            }

            // Add tool_call_id if present (for tool response messages)
            if (msg.tool_call_id) |tool_id| {
                try payload_list.appendSlice(self.allocator, ",\"tool_call_id\":\"");
                try payload_list.appendSlice(self.allocator, tool_id);
                try payload_list.append(self.allocator, '"');
            }

            // Add tool_calls if present (for assistant messages with tool calls)
            if (msg.tool_calls) |tc| {
                try payload_list.appendSlice(self.allocator, ",\"tool_calls\":[");
                for (tc, 0..) |tool_call, j| {
                    if (j > 0) try payload_list.append(self.allocator, ',');
                    try payload_list.appendSlice(self.allocator, "{\"id\":\"");
                    if (tool_call.id) |id| {
                        try payload_list.appendSlice(self.allocator, id);
                    } else {
                        try payload_list.appendSlice(self.allocator, "call_0");
                    }
                    try payload_list.appendSlice(self.allocator, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                    try payload_list.appendSlice(self.allocator, tool_call.function.name);
                    try payload_list.appendSlice(self.allocator, "\",\"arguments\":\"");

                    // Escape arguments (which is already a JSON string)
                    // If empty, use "{}" as OpenRouter expects valid JSON
                    const args = tool_call.function.arguments;
                    if (args.len == 0) {
                        try payload_list.appendSlice(self.allocator, "{}");
                    } else {
                        for (args) |c| {
                            if (c == '"') {
                                try payload_list.appendSlice(self.allocator, "\\\"");
                            } else if (c == '\\') {
                                try payload_list.appendSlice(self.allocator, "\\\\");
                            } else if (c == '\n') {
                                try payload_list.appendSlice(self.allocator, "\\n");
                            } else {
                                try payload_list.append(self.allocator, c);
                            }
                        }
                    }
                    try payload_list.appendSlice(self.allocator, "\"}}");
                }
                try payload_list.append(self.allocator, ']');
            }

            try payload_list.append(self.allocator, '}');
        }

        try payload_list.appendSlice(self.allocator, "],\"stream\":true");

        // Add optional parameters
        if (temperature) |temp| {
            try payload_list.appendSlice(self.allocator, ",\"temperature\":");
            const temp_str = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{temp});
            defer self.allocator.free(temp_str);
            try payload_list.appendSlice(self.allocator, temp_str);
        }

        if (num_predict) |max_tokens| {
            if (max_tokens > 0) {
                try payload_list.appendSlice(self.allocator, ",\"max_tokens\":");
                const tokens_str = try std.fmt.allocPrint(self.allocator, "{d}", .{max_tokens});
                defer self.allocator.free(tokens_str);
                try payload_list.appendSlice(self.allocator, tokens_str);
            }
        }

        // Add tools if provided
        if (tools) |tool_list| {
            try payload_list.appendSlice(self.allocator, ",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try payload_list.append(self.allocator, ',');
                try payload_list.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
                try payload_list.appendSlice(self.allocator, tool.function.name);
                try payload_list.appendSlice(self.allocator, "\",\"description\":\"");

                // Escape description
                for (tool.function.description) |c| {
                    if (c == '"') {
                        try payload_list.appendSlice(self.allocator, "\\\"");
                    } else if (c == '\\') {
                        try payload_list.appendSlice(self.allocator, "\\\\");
                    } else if (c == '\n') {
                        try payload_list.appendSlice(self.allocator, "\\n");
                    } else {
                        try payload_list.append(self.allocator, c);
                    }
                }

                try payload_list.appendSlice(self.allocator, "\",\"parameters\":");
                try payload_list.appendSlice(self.allocator, tool.function.parameters);
                try payload_list.appendSlice(self.allocator, "}}");
            }
            try payload_list.append(self.allocator, ']');
        }

        // Add response format if JSON mode requested
        if (format) |fmt| {
            if (std.mem.eql(u8, fmt, "json")) {
                try payload_list.appendSlice(self.allocator, ",\"response_format\":{\"type\":\"json_object\"}");
            }
        }

        try payload_list.append(self.allocator, '}');

        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        // DEBUG: Print request payload
        if (std.posix.getenv("DEBUG_OPENROUTER") != null) {
            std.debug.print("\n=== DEBUG: OpenRouter Request Payload ===\n{s}\n=== END PAYLOAD ===\n\n", .{payload});
        }

        // Make HTTP request
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/api/v1/chat/completions", .{self.base_url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        // Build Authorization header value
        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_value);

        // Headers: content-type, accept, authorization
        const headers_buffer = try self.allocator.alloc(http.Header, 3);
        defer self.allocator.free(headers_buffer);
        headers_buffer[0] = .{ .name = "content-type", .value = "application/json" };
        headers_buffer[1] = .{ .name = "accept", .value = "text/event-stream" };
        headers_buffer[2] = .{ .name = "authorization", .value = auth_value };

        var req = self.client.request(.POST, uri, .{
            .extra_headers = headers_buffer,
        }) catch |err| {
            std.debug.print("\n[OpenRouter] Failed to connect to {s}\n", .{self.base_url});
            std.debug.print("   Error: {s}\n", .{@errorName(err)});
            std.debug.print("\n   Check your internet connection and API key.\n", .{});
            std.debug.print("   Get an API key at: https://openrouter.ai/keys\n\n", .{});
            return err;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };

        // Send body
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();

        // Receive response
        if (std.posix.getenv("DEBUG_OPENROUTER") != null) {
            std.debug.print("DEBUG: Waiting for OpenRouter response...\n", .{});
        }
        const redirect_buffer = try self.allocator.alloc(u8, 8 * 1024);
        defer self.allocator.free(redirect_buffer);
        const response = try req.receiveHead(redirect_buffer);

        if (std.posix.getenv("DEBUG_OPENROUTER") != null) {
            std.debug.print("DEBUG: Got response status: {}\n", .{response.head.status});
        }

        if (response.head.status != .ok) {
            // Try to read error body for more details
            var error_body = std.ArrayListUnmanaged(u8){};
            defer error_body.deinit(self.allocator);

            const conn_reader = req.connection.?.reader();
            var error_read_buffer: [4096]u8 = undefined;
            while (true) {
                var read_vec = [_][]u8{&error_read_buffer};
                const bytes_read = conn_reader.*.readVec(&read_vec) catch break;
                if (bytes_read == 0) break;
                error_body.appendSlice(self.allocator, error_read_buffer[0..bytes_read]) catch break;
                if (error_body.items.len > 8192) break; // Limit error body size
            }

            std.debug.print("\n[OpenRouter] API error: {}\n", .{response.head.status});

            if (error_body.items.len > 0) {
                // Try to parse as OpenAI error format
                const error_parsed = json.parseFromSlice(
                    OpenAIErrorResponse,
                    self.allocator,
                    error_body.items,
                    .{ .ignore_unknown_fields = true },
                ) catch {
                    std.debug.print("   Response: {s}\n", .{error_body.items});
                    return error.BadStatus;
                };
                defer error_parsed.deinit();

                std.debug.print("   {s}\n", .{error_parsed.value.@"error".message});

                // Check for common errors
                if (response.head.status == .unauthorized) {
                    std.debug.print("\n   Your API key may be invalid or expired.\n", .{});
                    std.debug.print("   Get a new key at: https://openrouter.ai/keys\n", .{});
                } else if (response.head.status == .payment_required) {
                    std.debug.print("\n   You may need to add credits to your account.\n", .{});
                    std.debug.print("   Add credits at: https://openrouter.ai/credits\n", .{});
                }
            }

            std.debug.print("\n", .{});
            return error.BadStatus;
        }

        // Parse SSE stream using connection's reader
        if (std.posix.getenv("DEBUG_OPENROUTER") != null) {
            std.debug.print("DEBUG: Starting SSE stream parse...\n", .{});
        }
        const reader = req.connection.?.reader();
        try self.parseSSEStream(reader, context, callback);
        if (std.posix.getenv("DEBUG_OPENROUTER") != null) {
            std.debug.print("DEBUG: SSE stream parse completed\n", .{});
        }
    }

    /// Decode HTTP chunked transfer encoding
    /// Returns true if end of chunks reached, false if more data needed
    fn decodeChunkedData(
        self: *OpenRouterClient,
        raw_buffer: *std.ArrayListUnmanaged(u8),
        decoded_buffer: *std.ArrayListUnmanaged(u8),
    ) !bool {
        const debug_mode = std.posix.getenv("DEBUG_OPENROUTER") != null;

        while (true) {
            // Look for chunk size line (hex number followed by \r\n)
            const crlf_pos = std.mem.indexOf(u8, raw_buffer.items, "\r\n") orelse return false;

            // Parse chunk size (hex)
            const size_str = std.mem.trim(u8, raw_buffer.items[0..crlf_pos], " \t");
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch {
                if (debug_mode) {
                    std.debug.print("DEBUG: Failed to parse chunk size: '{s}'\n", .{size_str});
                }
                return error.InvalidChunkSize;
            };

            if (debug_mode) {
                std.debug.print("DEBUG: Decoded chunk size: {d} (0x{s})\n", .{ chunk_size, size_str });
            }

            // Check if we have the complete chunk data
            const chunk_start = crlf_pos + 2; // Skip \r\n after size
            const chunk_end = chunk_start + chunk_size;

            if (raw_buffer.items.len < chunk_end + 2) {
                // Incomplete chunk, need more data
                return false;
            }

            // Chunk size 0 means end of chunks
            if (chunk_size == 0) {
                if (debug_mode) {
                    std.debug.print("DEBUG: End of chunked encoding\n", .{});
                }
                return true;
            }

            // Extract chunk data and append to decoded buffer
            try decoded_buffer.appendSlice(self.allocator, raw_buffer.items[chunk_start..chunk_end]);

            // Remove processed chunk from raw buffer (including trailing \r\n)
            const remove_until = chunk_end + 2; // chunk data + \r\n
            const remaining = raw_buffer.items[remove_until..];
            std.mem.copyForwards(u8, raw_buffer.items, remaining);
            try raw_buffer.resize(self.allocator, remaining.len);
        }
    }

    /// Parse Server-Sent Events stream (with chunked encoding support)
    fn parseSSEStream(
        self: *OpenRouterClient,
        reader: anytype,
        context: anytype,
        callback: fn (
            ctx: @TypeOf(context),
            thinking_chunk: ?[]const u8,
            content_chunk: ?[]const u8,
            tool_calls_chunk: ?[]const ollama.ToolCall,
        ) void,
    ) !void {
        var raw_buffer = std.ArrayListUnmanaged(u8){}; // Raw HTTP data (chunked)
        defer raw_buffer.deinit(self.allocator);

        var decoded_buffer = std.ArrayListUnmanaged(u8){}; // Decoded SSE data
        defer decoded_buffer.deinit(self.allocator);

        var chunk_buffer: [8192]u8 = undefined;
        var accumulated_tool_calls = std.ArrayListUnmanaged(ollama.ToolCall){};
        defer {
            for (accumulated_tool_calls.items) |tc| {
                if (tc.id) |id| self.allocator.free(id);
                self.allocator.free(tc.function.name);
                self.allocator.free(tc.function.arguments);
            }
            accumulated_tool_calls.deinit(self.allocator);
        }

        const debug_mode = std.posix.getenv("DEBUG_OPENROUTER") != null;
        var stream_done = false; // Flag to exit outer loop when stream is complete

        while (!stream_done) {
            // Read raw data
            var read_vec = [_][]u8{&chunk_buffer};
            const bytes_read = reader.*.readVec(&read_vec) catch |err| {
                if (debug_mode) {
                    std.debug.print("DEBUG: Read error: {s}\n", .{@errorName(err)});
                }
                if (err == error.EndOfStream) break;
                return err;
            };
            if (bytes_read == 0) break;

            try raw_buffer.appendSlice(self.allocator, chunk_buffer[0..bytes_read]);

            // Decode chunked encoding
            _ = try self.decodeChunkedData(&raw_buffer, &decoded_buffer);

            // Process complete SSE lines from decoded buffer
            while (std.mem.indexOf(u8, decoded_buffer.items, "\n")) |newline_pos| {
                var line = decoded_buffer.items[0..newline_pos];

                // Trim \r from end of line (SSE uses \r\n line endings)
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }

                // Make a copy of the line before we modify the buffer
                const line_copy = try self.allocator.dupe(u8, line);
                defer self.allocator.free(line_copy);

                // Remove this line from decoded buffer
                const remaining = decoded_buffer.items[newline_pos + 1 ..];
                std.mem.copyForwards(u8, decoded_buffer.items, remaining);
                try decoded_buffer.resize(self.allocator, remaining.len);

                // Skip empty lines and comments
                if (line_copy.len == 0) continue;
                if (line_copy[0] == ':') continue;

                // Check for "data: " prefix (SSE format)
                if (std.mem.startsWith(u8, line_copy, "data: ")) {
                    const data = std.mem.trim(u8, line_copy[6..], " \r\n\t");

                    // Check for [DONE] signal - this ends the stream
                    if (std.mem.eql(u8, data, "[DONE]")) {
                        if (debug_mode) {
                            std.debug.print("DEBUG: Received [DONE] signal, ending stream\n", .{});
                        }
                        stream_done = true;
                        break;
                    }

                    // Parse JSON chunk
                    const parsed = json.parseFromSlice(
                        OpenAIStreamChunk,
                        self.allocator,
                        data,
                        .{ .ignore_unknown_fields = true },
                    ) catch |err| {
                        if (debug_mode) {
                            std.debug.print("[OpenRouter] Failed to parse SSE chunk: {s}\nData: {s}\n", .{ @errorName(err), data });
                        }
                        continue;
                    };
                    defer parsed.deinit();

                    const chunk = parsed.value;

                    // Extract content and tool calls from delta
                    if (chunk.choices) |choices| {
                        if (choices.len > 0 and choices[0].delta != null) {
                            const delta = choices[0].delta.?;

                            // Handle content
                            if (delta.content) |content| {
                                callback(context, null, content, null);
                            }

                            // Handle tool calls (accumulate them as they stream in)
                            if (delta.tool_calls) |tc_deltas| {
                                for (tc_deltas) |tc_delta| {
                                    if (tc_delta.index) |idx| {
                                        const index = @as(usize, @intCast(idx));

                                        // Ensure we have enough space
                                        while (accumulated_tool_calls.items.len <= index) {
                                            try accumulated_tool_calls.append(self.allocator, .{
                                                .id = null,
                                                .type = null,
                                                .function = .{
                                                    .name = try self.allocator.dupe(u8, ""),
                                                    .arguments = try self.allocator.dupe(u8, ""),
                                                },
                                            });
                                        }

                                        // Update the accumulated tool call
                                        var tc = &accumulated_tool_calls.items[index];

                                        if (tc_delta.id) |id| {
                                            if (tc.id) |old_id| self.allocator.free(old_id);
                                            tc.id = try self.allocator.dupe(u8, id);
                                        }

                                        if (tc_delta.type) |tc_type| {
                                            if (tc.type) |old_type| self.allocator.free(old_type);
                                            tc.type = try self.allocator.dupe(u8, tc_type);
                                        }

                                        if (tc_delta.function) |func| {
                                            if (func.name) |name| {
                                                const old_name = tc.function.name;
                                                tc.function.name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ old_name, name });
                                                self.allocator.free(old_name);
                                            }

                                            if (func.arguments) |args| {
                                                const old_args = tc.function.arguments;
                                                tc.function.arguments = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ old_args, args });
                                                self.allocator.free(old_args);
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Check if this is the final chunk with finish_reason
                        // This comes on a separate chunk after content is done
                        if (choices.len > 0) {
                            if (choices[0].finish_reason) |reason| {
                                if (debug_mode) {
                                    std.debug.print("DEBUG: Received finish_reason: {s}\n", .{reason});
                                }
                                // Handle tool_calls finish - send accumulated tool calls
                                if (std.mem.eql(u8, reason, "tool_calls")) {
                                    if (accumulated_tool_calls.items.len > 0) {
                                        // Normalize empty arguments to "{}" before sending
                                        for (accumulated_tool_calls.items) |*tc| {
                                            if (tc.function.arguments.len == 0) {
                                                self.allocator.free(tc.function.arguments);
                                                tc.function.arguments = try self.allocator.dupe(u8, "{}");
                                            }
                                        }
                                        const owned_calls = try accumulated_tool_calls.toOwnedSlice(self.allocator);
                                        callback(context, null, null, owned_calls);
                                    }
                                }
                                // Note: "stop", "length", "content_filter" all indicate completion
                                // The [DONE] signal will follow shortly to end the stream
                            }
                        }
                    }
                }
            }
        }

        // If we accumulated tool calls but never got a finish_reason, send them now
        if (accumulated_tool_calls.items.len > 0) {
            // Normalize empty arguments to "{}" before sending
            for (accumulated_tool_calls.items) |*tc| {
                if (tc.function.arguments.len == 0) {
                    self.allocator.free(tc.function.arguments);
                    tc.function.arguments = try self.allocator.dupe(u8, "{}");
                }
            }
            const owned_calls = try accumulated_tool_calls.toOwnedSlice(self.allocator);
            callback(context, null, null, owned_calls);
        }
    }
};
