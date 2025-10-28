// src/zerver/runtime/handler.zig
/// Request and response handling for HTTP connections
///
/// This module handles reading HTTP requests from sockets and sending responses,
/// with platform-specific optimizations for Windows vs Unix.
const request_reader = @import("http/request_reader.zig");
const response_writer = @import("http/response/writer.zig");
const response_formatter = @import("http/response/formatter.zig");
const response_sse = @import("http/response/sse.zig");

pub const readRequestWithTimeout = request_reader.readRequestWithTimeout;
pub const sendResponse = response_writer.sendResponse;
pub const sendStreamingResponse = response_writer.sendStreamingResponse;
pub const sendErrorResponse = response_writer.sendErrorResponse;
pub const formatResponse = response_formatter.formatResponse;
pub const ResponseFormatOptions = response_formatter.FormatOptions;
pub const ResponseCorrelationHeader = response_formatter.CorrelationHeader;
pub const SSEEvent = response_sse.SSEEvent;
pub const formatSSEEvent = response_sse.formatEvent;
pub const createSSEResponse = response_sse.createResponse;
