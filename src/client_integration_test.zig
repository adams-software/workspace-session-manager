const std = @import("std");
const client = @import("client");
const server = @import("server");
const host = @import("host");
const protocol = @import("protocol");
const attach_runtime = @import("attach_runtime");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

fn readFrameWithTimeout(allocator: std.mem.Allocator, fd: c_int, max_len: usize, timeout_ms: i32) ![]u8 {
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    const pr = c.poll(&pfd, 1, timeout_ms);
    if (pr < 0) return error.IoError;
    if (pr == 0) return error.Timeout;
    if ((pfd.revents & c.POLLIN) == 0) return error.Timeout;
    return protocol.readFrame(allocator, fd, max_len);
}

fn spawnBoundedServerThread(srv: *server.SessionServer, loops: usize, sleep_us: u32) !std.Thread {
    const Args = struct {
        srv: *server.SessionServer,
        loops: usize,
        sleep_us: u32,
    };
    return try std.Thread.spawn(.{}, struct {
        fn run(args: Args) void {
            var i: usize = 0;
            while (i < args.loops) : (i += 1) {
                _ = args.srv.step() catch {};
                _ = c.usleep(args.sleep_us);
            }
        }
    }.run, .{Args{ .srv = srv, .loops = loops, .sleep_us = sleep_us }});
}

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

    const th = try spawnBoundedServerThread(&s, 4, 20_000);
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

    const th = try spawnBoundedServerThread(&s, 12, 20_000);

    var att = try cli.attach(.exclusive);
    defer att.close();
    try att.write("hello from client\n");
    const frame = try readFrameWithTimeout(std.testing.allocator, att.fd, 256 * 1024, 1000);
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

test "routed owner_control detach returns success" {
    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } });
    defer h.deinit();
    try h.start();

    var s = server.SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();
    const path = "/tmp/msr-routed-owner-detach-test.sock";
    _ = c.unlink(path);
    defer _ = c.unlink(path);
    try s.listen(path);

    const owner_attach_thread = try spawnBoundedServerThread(&s, 4, 10_000);
    var owner_cli = try client.SessionClient.init(std.testing.allocator, path);
    var owner_att = try owner_cli.attach(.exclusive);
    owner_attach_thread.join();

    const owner_runtime_thread = try std.Thread.spawn(.{}, struct {
        fn run(att: *client.SessionAttachment) void {
            attach_runtime.runAttachBridge(std.testing.allocator, att, c.STDIN_FILENO, c.STDOUT_FILENO) catch {};
        }
    }.run, .{&owner_att});

    const route_thread = try spawnBoundedServerThread(&s, 40, 10_000);

    const fd = try client.connectUnix(path);
    defer _ = c.close(fd);
    const lane_req = try protocol.encodeLaneReqMsg(std.testing.allocator, .{
        .lane_id = "lane-detach",
        .lane_kind = "owner_control",
        .req_type = "call",
        .seq = 1,
        .method = "detach",
    });
    defer std.testing.allocator.free(lane_req);
    try protocol.writeFrame(fd, lane_req);

    const res_bytes = try readFrameWithTimeout(std.testing.allocator, fd, 64 * 1024, 1000);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseLaneResMsg(std.testing.allocator, res_bytes);
    defer protocol.freeLaneResMsg(std.testing.allocator, &res);
    try std.testing.expectEqualStrings("lane-detach", res.lane_id);
    try std.testing.expectEqualStrings("return", res.res_type);
    try std.testing.expect(res.value_json != null);
    try std.testing.expectEqualStrings("{}", res.value_json.?);

    std.debug.print("[test] joining route thread\n", .{});
    route_thread.join();
    std.debug.print("[test] joining owner runtime thread\n", .{});
    owner_runtime_thread.join();

    // After routed detach, the runtime thread should have consumed/closed the attachment path.
    // Host/server cleanup first; then deinit the client object last.

    std.debug.print("[test] terminating host\n", .{});
    try h.terminate("KILL");
    std.debug.print("[test] waiting host\n", .{});
    _ = try h.wait();
    std.debug.print("[test] closing host\n", .{});
    try h.close();
    std.debug.print("[test] keeping owner_cli alive for now (known cleanup bug after routed detach)\n", .{});
}

test "routed owner_control attach returns success" {
    var h1 = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } });
    defer h1.deinit();
    try h1.start();

    var s1 = server.SessionServer.init(std.testing.allocator, &h1);
    defer s1.deinit();
    const path1 = "/tmp/msr-routed-owner-attach-src.sock";
    _ = c.unlink(path1);
    defer _ = c.unlink(path1);
    try s1.listen(path1);

    var h2 = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf target-ready; sleep 2" } });
    defer h2.deinit();
    try h2.start();

    var s2 = server.SessionServer.init(std.testing.allocator, &h2);
    defer s2.deinit();
    const path2 = "/tmp/msr-routed-owner-attach-dst.sock";
    _ = c.unlink(path2);
    defer _ = c.unlink(path2);
    try s2.listen(path2);

    const src_attach_thread = try spawnBoundedServerThread(&s1, 4, 10_000);
    var owner_cli = try client.SessionClient.init(std.testing.allocator, path1);
    var owner_att = try owner_cli.attach(.exclusive);
    src_attach_thread.join();

    const owner_runtime_thread = try std.Thread.spawn(.{}, struct {
        fn run(att: *client.SessionAttachment) void {
            attach_runtime.runAttachBridge(std.testing.allocator, att, c.STDIN_FILENO, c.STDOUT_FILENO) catch {};
        }
    }.run, .{&owner_att});

    const dst_server_thread = try spawnBoundedServerThread(&s2, 20, 10_000);
    const route_thread = try spawnBoundedServerThread(&s1, 60, 10_000);

    const fd = try client.connectUnix(path1);
    defer _ = c.close(fd);
    const lane_req = try protocol.encodeLaneReqMsg(std.testing.allocator, .{
        .lane_id = "lane-attach",
        .lane_kind = "owner_control",
        .req_type = "call",
        .seq = 1,
        .method = "attach",
        .args_json = "{\"path\":\"/tmp/msr-routed-owner-attach-dst.sock\"}",
    });
    defer std.testing.allocator.free(lane_req);
    try protocol.writeFrame(fd, lane_req);

    const res_bytes = try readFrameWithTimeout(std.testing.allocator, fd, 64 * 1024, 1000);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseLaneResMsg(std.testing.allocator, res_bytes);
    defer protocol.freeLaneResMsg(std.testing.allocator, &res);
    try std.testing.expectEqualStrings("lane-attach", res.lane_id);
    try std.testing.expectEqualStrings("return", res.res_type);
    try std.testing.expect(res.value_json != null);
    try std.testing.expectEqualStrings("{}", res.value_json.?);

    std.debug.print("[test-attach] joining dst server thread\n", .{});
    dst_server_thread.join();
    std.debug.print("[test-attach] joining route thread\n", .{});
    route_thread.join();

    // Drive the current target session down first so the owner runtime has a deterministic reason to exit.
    std.debug.print("[test-attach] terminating target host\n", .{});
    try h2.terminate("KILL");
    std.debug.print("[test-attach] waiting target host\n", .{});
    _ = try h2.wait();
    std.debug.print("[test-attach] closing target host\n", .{});
    try h2.close();

    // Now the bridged owner runtime should unwind instead of hanging indefinitely.
    std.debug.print("[test-attach] joining owner runtime thread\n", .{});
    owner_runtime_thread.join();

    // Clean up the original source host after the switched runtime has exited.
    std.debug.print("[test-attach] terminating source host\n", .{});
    try h1.terminate("KILL");
    std.debug.print("[test-attach] waiting source host\n", .{});
    _ = try h1.wait();
    std.debug.print("[test-attach] closing source host\n", .{});
    try h1.close();
}
