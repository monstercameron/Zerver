// src/zerver/runtime/http/headers.zig
/// Header parsing utilities for HTTP/1.1 requests.
const std = @import("std");

fn charIsEscaped(segment: []const u8, index: usize) bool {
    var count: usize = 0;
    var i = index;

    while (i > 0) {
        i -= 1;
        if (segment[i] == '\\') {
            count += 1;
        } else {
            break;
        }
    }

    return count % 2 == 1;
}

pub fn sanitizeHeaderSegment(segment: []const u8, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) ![]const u8 {
    buffer.clearRetainingCapacity();
    try buffer.ensureTotalCapacity(allocator, segment.len);

    var i: usize = 0;
    var in_quotes = false;
    var comment_depth: usize = 0;

    while (i < segment.len) {
        const c = segment[i];
        const escaped = charIsEscaped(segment, i);

        if (comment_depth > 0) {
            if (!escaped and c == '(') {
                comment_depth += 1;
            } else if (!escaped and c == ')') {
                comment_depth -= 1;
                if (comment_depth == 0) {
                    i += 1;
                    continue;
                }
            } else if (c == '\\' and i + 1 < segment.len) {
                i += 2;
                continue;
            }

            i += 1;
            continue;
        }

        if (!escaped and !in_quotes and c == '(') {
            comment_depth = 1;
            i += 1;
            continue;
        }

        if (!escaped and c == '"') {
            in_quotes = !in_quotes;
        }

        try buffer.append(allocator, c);
        i += 1;
    }

    return buffer.items;
}

pub fn normalizeQuotedString(value: []const u8, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) ![]const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        buffer.clearRetainingCapacity();
        try buffer.ensureTotalCapacity(allocator, value.len - 2);

        var i: usize = 1;
        while (i < value.len - 1) {
            const c = value[i];
            if (c == '\\' and i + 1 < value.len - 1) {
                try buffer.append(allocator, value[i + 1]);
                i += 2;
                continue;
            }

            try buffer.append(allocator, c);
            i += 1;
        }

        return buffer.items;
    }

    return value;
}

pub fn parseQValue(raw: []const u8) ?u16 {
    if (raw.len == 0) return null;
    const first = raw[0];
    if (first != '0' and first != '1') return null;

    if (raw.len == 1) {
        return if (first == '1') 1000 else 0;
    }

    if (raw.len < 3 or raw[1] != '.') return null;

    var idx: usize = 2;
    var decimals: usize = 0;
    var decimal_value: u16 = 0;

    while (idx < raw.len) : (idx += 1) {
        const c = raw[idx];
        if (c < '0' or c > '9') return null;
        if (decimals == 3) return null;
        const digit = @as(u16, c) - @as(u16, '0');
        decimal_value = decimal_value * 10 + digit;
        decimals += 1;
    }

    if (first == '1' and decimal_value != 0) return null;

    while (decimals < 3) : (decimals += 1) {
        decimal_value *= 10;
    }

    if (first == '1') {
        return 1000;
    }

    return decimal_value;
}

pub fn qAllowsSelection(params: []const u8, allocator: std.mem.Allocator) bool {
    if (params.len == 0) return true;

    var token_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch return false;
    defer token_buffer.deinit(allocator);

    var allows = true;
    var param_it = std.mem.splitSequence(u8, params, ";");
    while (param_it.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (trimmed.len == 0) continue;

        const sanitized_raw = sanitizeHeaderSegment(trimmed, &token_buffer, allocator) catch return false;
        const sanitized = std.mem.trim(u8, sanitized_raw, " \t");
        if (sanitized.len == 0) continue;

        const eq_idx = std.mem.indexOfScalar(u8, sanitized, '=') orelse continue;
        const name = std.mem.trim(u8, sanitized[0..eq_idx], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "q")) continue;

        const raw_value = std.mem.trim(u8, sanitized[eq_idx + 1 ..], " \t");
        if (raw_value.len == 0) {
            allows = false;
            break;
        }

        if (std.mem.indexOfScalar(u8, raw_value, '"') != null) {
            allows = false;
            break;
        }

        const parsed_q = parseQValue(raw_value) orelse {
            allows = false;
            break;
        };

        if (parsed_q == 0) {
            allows = false;
            break;
        }
    }

    return allows;
}

pub fn mediaMatchesTextPlain(media: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(media, "*/*")) {
        return true;
    }

    const slash_idx = std.mem.indexOfScalar(u8, media, '/') orelse return false;
    const type_part = media[0..slash_idx];
    const subtype_part = media[slash_idx + 1 ..];

    if (!std.ascii.eqlIgnoreCase(type_part, "text")) {
        return false;
    }

    return std.ascii.eqlIgnoreCase(subtype_part, "plain") or std.ascii.eqlIgnoreCase(subtype_part, "*");
}

pub fn acceptsTextPlain(values: []const []const u8, allocator: std.mem.Allocator) bool {
    var token_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch return false;
    defer token_buffer.deinit(allocator);

    var saw_media = false;

    for (values) |raw_value| {
        var token_it = std.mem.splitSequence(u8, raw_value, ",");
        while (token_it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (trimmed.len == 0) continue;

            const sanitized_raw = sanitizeHeaderSegment(trimmed, &token_buffer, allocator) catch return false;
            const sanitized = std.mem.trim(u8, sanitized_raw, " \t");
            if (sanitized.len == 0) continue;

            saw_media = true;

            const semicolon_idx = std.mem.indexOfScalar(u8, sanitized, ';');
            const media = if (semicolon_idx) |idx| std.mem.trim(u8, sanitized[0..idx], " \t") else sanitized;
            const params = if (semicolon_idx) |idx| sanitized[idx + 1 ..] else "";

            if (qAllowsSelection(params, allocator) and mediaMatchesTextPlain(media)) {
                return true;
            }
        }
    }

    return !saw_media;
}

pub fn languageMatchesEnglish(language_range: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(language_range, "*")) {
        return true;
    }

    if (std.mem.indexOfScalar(u8, language_range, '-')) |idx| {
        const primary = language_range[0..idx];
        return std.ascii.eqlIgnoreCase(primary, "en");
    }

    return std.ascii.eqlIgnoreCase(language_range, "en");
}

pub fn acceptLanguageAllowsEnglish(values: []const []const u8, allocator: std.mem.Allocator) bool {
    var token_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch return false;
    defer token_buffer.deinit(allocator);

    var saw_language = false;

    for (values) |raw_value| {
        var token_it = std.mem.splitSequence(u8, raw_value, ",");
        while (token_it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (trimmed.len == 0) continue;

            const sanitized_raw = sanitizeHeaderSegment(trimmed, &token_buffer, allocator) catch return false;
            const sanitized = std.mem.trim(u8, sanitized_raw, " \t");
            if (sanitized.len == 0) continue;

            saw_language = true;

            const semicolon_idx = std.mem.indexOfScalar(u8, sanitized, ';');
            const language_range = std.mem.trim(u8, if (semicolon_idx) |idx| sanitized[0..idx] else sanitized, " \t");
            const params = if (semicolon_idx) |idx| sanitized[idx + 1 ..] else "";

            if (language_range.len == 0) continue;

            if (qAllowsSelection(params, allocator) and languageMatchesEnglish(language_range)) {
                return true;
            }
        }
    }

    return !saw_language;
}

pub fn contentTypeMatchesTextPlain(value: []const u8, quoted_buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) bool {
    const semicolon_idx = std.mem.indexOfScalar(u8, value, ';');
    const media_token = if (semicolon_idx) |idx| std.mem.trim(u8, value[0..idx], " \t") else std.mem.trim(u8, value, " \t");

    if (!std.ascii.eqlIgnoreCase(media_token, "text/plain")) {
        return false;
    }

    if (semicolon_idx == null) {
        return true;
    }

    const params = value[semicolon_idx.? + 1 ..];
    var charset_allowed: ?bool = null;

    var param_it = std.mem.splitSequence(u8, params, ";");
    while (param_it.next()) |param_segment| {
        const trimmed = std.mem.trim(u8, param_segment, " \t");
        if (trimmed.len == 0) continue;

        const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        const raw_value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "charset")) {
            const normalized = normalizeQuotedString(raw_value, quoted_buffer, allocator) catch return false;
            if (!std.ascii.eqlIgnoreCase(normalized, "utf-8")) {
                return false;
            }
            charset_allowed = true;
        }
    }

    if (charset_allowed) |allowed| {
        return allowed;
    }

    return true;
}

pub fn contentTypeAllowsTextPlain(values: []const []const u8, allocator: std.mem.Allocator) bool {
    var saw_token = false;
    var token_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch return false;
    defer token_buffer.deinit(allocator);
    var quoted_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch return false;
    defer quoted_buffer.deinit(allocator);

    for (values) |raw_value| {
        var token_it = std.mem.splitSequence(u8, raw_value, ",");
        while (token_it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (trimmed.len == 0) continue;

            if (saw_token) {
                return false;
            }

            const sanitized_raw = sanitizeHeaderSegment(trimmed, &token_buffer, allocator) catch return false;
            const sanitized = std.mem.trim(u8, sanitized_raw, " \t");
            if (sanitized.len == 0) continue;

            saw_token = true;
            if (!contentTypeMatchesTextPlain(sanitized, &quoted_buffer, allocator)) {
                return false;
            }
        }
    }

    return saw_token;
}

pub fn acceptCharsetAllowsUtf8(values: []const []const u8, allocator: std.mem.Allocator) bool {
    var token_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch return false;
    defer token_buffer.deinit(allocator);

    var saw_charset = false;
    var utf8_allowed: ?bool = null;
    var wildcard_allowed: ?bool = null;

    for (values) |raw_value| {
        var token_it = std.mem.splitSequence(u8, raw_value, ",");
        while (token_it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (trimmed.len == 0) continue;

            const sanitized_raw = sanitizeHeaderSegment(trimmed, &token_buffer, allocator) catch return false;
            const sanitized = std.mem.trim(u8, sanitized_raw, " \t");
            if (sanitized.len == 0) continue;

            saw_charset = true;

            const semicolon_idx = std.mem.indexOfScalar(u8, sanitized, ';');
            const charset = std.mem.trim(u8, if (semicolon_idx) |idx| sanitized[0..idx] else sanitized, " \t");
            const params = if (semicolon_idx) |idx| sanitized[idx + 1 ..] else "";
            const q_ok = qAllowsSelection(params, allocator);

            if (charset.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(charset, "utf-8")) {
                utf8_allowed = q_ok;
            } else if (std.ascii.eqlIgnoreCase(charset, "*")) {
                wildcard_allowed = q_ok;
            }
        }
    }

    if (utf8_allowed) |allowed| {
        return allowed;
    }

    if (wildcard_allowed) |allowed| {
        return allowed;
    }

    return !saw_charset;
}

pub fn acceptEncodingAllowsIdentity(values: []const []const u8, allocator: std.mem.Allocator) bool {
    var token_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch return false;
    defer token_buffer.deinit(allocator);

    var identity_allowed_explicit: ?bool = null;
    var wildcard_allowed: ?bool = null;

    for (values) |raw_value| {
        var token_it = std.mem.splitSequence(u8, raw_value, ",");
        while (token_it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (trimmed.len == 0) continue;

            const sanitized_raw = sanitizeHeaderSegment(trimmed, &token_buffer, allocator) catch return false;
            const sanitized = std.mem.trim(u8, sanitized_raw, " \t");
            if (sanitized.len == 0) continue;

            const semicolon_idx = std.mem.indexOfScalar(u8, sanitized, ';');
            const encoding = std.mem.trim(u8, if (semicolon_idx) |idx| sanitized[0..idx] else sanitized, " \t");
            const params = if (semicolon_idx) |idx| sanitized[idx + 1 ..] else "";
            const q_ok = qAllowsSelection(params, allocator);

            if (encoding.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(encoding, "identity")) {
                identity_allowed_explicit = q_ok;
            } else if (std.ascii.eqlIgnoreCase(encoding, "*")) {
                wildcard_allowed = q_ok;
            }
        }
    }

    if (identity_allowed_explicit) |allowed| {
        return allowed;
    }

    if (wildcard_allowed) |allowed| {
        return allowed;
    }

    return true;
}
