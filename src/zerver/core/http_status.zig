// src/zerver/core/http_status.zig
/// Canonical HTTP status codes used across Zerver.
pub const HttpStatus = struct {
    // 1xx Informational
    pub const continue_: u16 = 100;
    pub const switching_protocols: u16 = 101;
    pub const processing: u16 = 102;
    pub const early_hints: u16 = 103;

    // 2xx Success
    pub const ok: u16 = 200;
    pub const created: u16 = 201;
    pub const accepted: u16 = 202;
    pub const non_authoritative_information: u16 = 203;
    pub const no_content: u16 = 204;
    pub const reset_content: u16 = 205;
    pub const partial_content: u16 = 206;
    pub const multi_status: u16 = 207;
    pub const already_reported: u16 = 208;
    pub const im_used: u16 = 226;

    // 3xx Redirection
    pub const multiple_choices: u16 = 300;
    pub const moved_permanently: u16 = 301;
    pub const found: u16 = 302;
    pub const see_other: u16 = 303;
    pub const not_modified: u16 = 304;
    pub const use_proxy: u16 = 305;
    pub const unused: u16 = 306;
    pub const temporary_redirect: u16 = 307;
    pub const permanent_redirect: u16 = 308;

    // 4xx Client errors
    pub const bad_request: u16 = 400;
    pub const unauthorized: u16 = 401;
    pub const payment_required: u16 = 402;
    pub const forbidden: u16 = 403;
    pub const not_found: u16 = 404;
    pub const method_not_allowed: u16 = 405;
    pub const not_acceptable: u16 = 406;
    pub const proxy_authentication_required: u16 = 407;
    pub const request_timeout: u16 = 408;
    pub const conflict: u16 = 409;
    pub const gone: u16 = 410;
    pub const length_required: u16 = 411;
    pub const precondition_failed: u16 = 412;
    pub const payload_too_large: u16 = 413;
    pub const uri_too_long: u16 = 414;
    pub const unsupported_media_type: u16 = 415;
    pub const range_not_satisfiable: u16 = 416;
    pub const expectation_failed: u16 = 417;
    pub const im_a_teapot: u16 = 418;
    pub const misdirected_request: u16 = 421;
    pub const unprocessable_content: u16 = 422;
    pub const locked: u16 = 423;
    pub const failed_dependency: u16 = 424;
    pub const too_early: u16 = 425;
    pub const upgrade_required: u16 = 426;
    pub const precondition_required: u16 = 428;
    pub const too_many_requests: u16 = 429;
    pub const request_header_fields_too_large: u16 = 431;
    pub const unavailable_for_legal_reasons: u16 = 451;

    // 5xx Server errors
    pub const internal_server_error: u16 = 500;
    pub const not_implemented: u16 = 501;
    pub const bad_gateway: u16 = 502;
    pub const service_unavailable: u16 = 503;
    pub const gateway_timeout: u16 = 504;
    pub const http_version_not_supported: u16 = 505;
    pub const variant_also_negotiates: u16 = 506;
    pub const insufficient_storage: u16 = 507;
    pub const loop_detected: u16 = 508;
    pub const not_extended: u16 = 510;
    pub const network_authentication_required: u16 = 511;

    /// Determine whether a code falls within the valid HTTP status range.
    pub fn isValid(code: u16) bool {
        return code >= 100 and code <= 599;
    }

    /// Determine if status code is informational (1xx).
    pub inline fn isInformational(code: u16) bool {
        return code >= 100 and code < 200;
    }

    /// Determine if status code is success (2xx).
    pub inline fn isSuccess(code: u16) bool {
        return code >= 200 and code < 300;
    }

    /// Determine if status code is redirection (3xx).
    pub inline fn isRedirection(code: u16) bool {
        return code >= 300 and code < 400;
    }

    /// Determine if status code is client error (4xx).
    pub inline fn isClientError(code: u16) bool {
        return code >= 400 and code < 500;
    }

    /// Determine if status code is server error (5xx).
    pub inline fn isServerError(code: u16) bool {
        return code >= 500 and code < 600;
    }
};
