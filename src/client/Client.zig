//! Server which listens for Websocket Handshakes.
//! Only need to call `deinit()` if created via `init(Address)`.
//! If you have an existing `std.net.Server`, it is okay to create this struct via struct initialization.

const std = @import("std");
const client = @import("../root.zig").client;

const b64_encoder = std.base64.standard.Encoder;

http_client: std.http.Client,

const Client = @This();

pub fn init(allocator: std.mem.Allocator) !Client {
    const http_client = std.http.Client{ .allocator = allocator };
    return .{ .http_client = http_client };
}

pub fn handshake(self: *Client, uri: std.Uri) !void {
    var buf: [1000]u8 = undefined;
    const websocket_key = generateRandomWebsocketKey();

    var req = try self.http_client.open(.GET, uri, .{
        .server_header_buffer = &buf,
        .extra_headers = &.{
            std.http.Header{ .name = "Upgrade", .value = "websocket" },
            std.http.Header{ .name = "Connection", .value = "Upgrade" },
            std.http.Header{ .name = "Sec-WebSocket-Key", .value = &websocket_key },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .switching_protocols) {
        return error.NotWebsocketServer;
    }

    const expected_ws_accept = expectedWebsocketAcceptHeader(websocket_key);
    var upgrade_seen = false;
    var connection_seen = false;
    var accept_seen = false;
    var headers_iter = req.response.iterateHeaders();
    while (headers_iter.next()) |header| {
        if (std.mem.eql(u8, header.name, "Upgrade")) {
            upgrade_seen = true;
            if (!std.mem.eql(u8, header.value, "websocket")) {
                return error.NotWebsocketServer;
            }
        }
        if (std.mem.eql(u8, header.name, "Connection")) {
            connection_seen = true;
            if (!std.mem.eql(u8, header.value, "Upgrade")) {
                return error.NotWebsocketServer;
            }
        }
        if (std.mem.eql(u8, header.name, "Sec-WebSocket-Accept")) {
            accept_seen = true;
            if (!std.mem.eql(u8, header.value, &expected_ws_accept)) {
                return error.NotWebsocketServer;
            }
        }
    }
    if (!upgrade_seen or !connection_seen or !accept_seen) {
        return error.NotWebsocketServer;
    }
}

pub fn deinit(self: *Client) void {
    self.http_client.deinit();
}

fn generateRandomWebsocketKey() [b64_encoder.calcSize(16)]u8 {
    var rand = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    var buf: [16]u8 = undefined;
    var out_buf: [b64_encoder.calcSize(16)]u8 = undefined;
    rand.random().bytes(&buf);
    _ = b64_encoder.encode(&out_buf, &buf);

    return out_buf;
}

fn expectedWebsocketAcceptHeader(key: [b64_encoder.calcSize(16)]u8) [b64_encoder.calcSize(20)]u8 {
    const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var buf: [key.len + ws_guid.len]u8 = undefined;
    std.mem.copyForwards(u8, buf[0..key.len], &key);
    std.mem.copyForwards(u8, buf[key.len..], ws_guid);

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(&buf);

    const digest = sha1.finalResult();
    var out_buf: [b64_encoder.calcSize(digest.len)]u8 = undefined;
    _ = b64_encoder.encode(&out_buf, &digest);

    return out_buf;
}

test "expected websocket accept header from spec" {
    try std.testing.expectEqual(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".*,
        expectedWebsocketAcceptHeader("dGhlIHNhbXBsZSBub25jZQ==".*),
    );
}
