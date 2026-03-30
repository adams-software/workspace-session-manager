const std = @import("std");
const client = @import("client");
const server = @import("server");
const host = @import("host");
const protocol = @import("protocol");
const c = @cImport({
    @cInclude("unistd.h");
});

test "client status roundtrip" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = server.SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();
    const path = "/tmp/msr-client-status-test.sock";
    _ = c.unlink(path);
    defer _ = c.unlink(path);
    try s.listen(path);

    var cli = try client.SessionClient.init(std.testing.allocator, path);
    defer cli.deinit();

    const th = try std.Thread.spawn(.{}, struct {
        fn run(srv: *server.SessionServer) void {
            _ = srv.step() catch {};
        }
    }.run, .{&s});
    const st = try cli.status();
    defer std.testing.allocator.free(@constCast(st.status));
    try std.testing.expectEqualStrings("running", st.status);
    th.join();

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "client attach/write/read/detach roundtrip" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "read line; printf 'got:%s' \"$line\"; sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = server.SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();
    const path = "/tmp/msr-client-attach-test.sock";
    _ = c.unlink(path);
    defer _ = c.unlink(path);
    try s.listen(path);

    var cli = try client.SessionClient.init(std.testing.allocator, path);
    defer cli.deinit();

    const th = try std.Thread.spawn(.{}, struct {
        fn run(srv: *server.SessionServer) void {
            var i: usize = 0;
            while (i < 6) : (i += 1) {
                _ = srv.step() catch {};
                _ = c.usleep(20_000);
            }
        }
    }.run, .{&s});

    var att = try cli.attach(.exclusive);
    defer att.close();
    try att.write("hello from client\n");
    const frame = try att.readFrameOwned();
    defer std.testing.allocator.free(frame);
    var msg = try protocol.parseDataMsg(std.testing.allocator, frame);
    defer protocol.freeDataMsg(std.testing.allocator, &msg);
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64);
    const decoded = try std.testing.allocator.alloc(u8, decoded_len);
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, msg.bytes_b64);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "got:hello from client") != null);
    try att.detach();
    th.join();

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}
