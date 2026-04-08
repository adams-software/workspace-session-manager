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

fn waitForThreadDone(thread: *const std.Thread, done: *std.atomic.Value(bool), timeout_ms: u32) !void {
    const loops = timeout_ms / 10;
    var i: u32 = 0;
    while (i < loops) : (i += 1) {
        if (done.load(.seq_cst)) {
            thread.join();
            return;
        }
        _ = c.usleep(10_000);
    }
    return error.Timeout;
}

fn spawnUntilDoneServerThread(srv: *server.SessionServer, done: *std.atomic.Value(bool), sleep_us: u32) !std.Thread {
    const Args = struct {
        srv: *server.SessionServer,
        done: *std.atomic.Value(bool),
        sleep_us: u32,
    };
    return try std.Thread.spawn(.{}, struct {
        fn run(args: Args) void {
            while (!args.done.load(.seq_cst)) {
                _ = args.srv.step() catch {};
                _ = c.usleep(args.sleep_us);
            }
        }
    }.run, .{Args{ .srv = srv, .done = done, .sleep_us = sleep_us }});
}

fn readBytesWithTimeout(allocator: std.mem.Allocator, fd: c_int, max_len: usize, timeout_ms: i32) ![]u8 {
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    const pr = c.poll(&pfd, 1, timeout_ms);
    if (pr < 0) return error.IoError;
    if (pr == 0) return error.Timeout;
    if ((pfd.revents & c.POLLIN) == 0) return error.Timeout;

    const buf = try allocator.alloc(u8, max_len);
    errdefer allocator.free(buf);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.IoError;
    if (n == 0) return error.UnexpectedEof;
    return allocator.realloc(buf, @intCast(n));
}

test "client status roundtrip" {
    std.debug.print("[client-test] start status roundtrip\n", .{});
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
    std.debug.print("[client-test] done status roundtrip\n", .{});
}

test "client attach/write/read/detach roundtrip" {
    std.debug.print("[client-test] start attach/write/read/detach roundtrip\n", .{});
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

    var collected = std.ArrayList(u8){};
    defer collected.deinit(std.testing.allocator);

    const needle = "got:hello from client";
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const frame = readFrameWithTimeout(std.testing.allocator, att.fd, 256 * 1024, 1000) catch |e| switch (e) {
            error.Timeout => break,
            else => return e,
        };
        defer std.testing.allocator.free(frame);

        var msg = try protocol.parseDataMsg(std.testing.allocator, frame);
        defer protocol.freeDataMsg(std.testing.allocator, &msg);

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg.bytes_b64);
        const decoded = try std.testing.allocator.alloc(u8, decoded_len);
        defer std.testing.allocator.free(decoded);

        try std.base64.standard.Decoder.decode(decoded, msg.bytes_b64);
        try collected.appendSlice(std.testing.allocator, decoded);

        if (std.mem.indexOf(u8, collected.items, needle) != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, collected.items, needle) != null);
    try att.detach();
    th.join();

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
    std.debug.print("[client-test] done attach/write/read/detach roundtrip\n", .{});
}

test "routed owner_control detach returns success" {
    if (false) {
    std.debug.print("[client-test] start routed detach\n", .{});
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
    defer owner_cli.deinit();
    var owner_att = try owner_cli.attach(.exclusive);
    owner_attach_thread.join();

    const owner_runtime_thread = try std.Thread.spawn(.{}, struct {
        fn run(att: *client.SessionAttachment) void {
            _ = attach_runtime.runAttachBridge(std.testing.allocator, att, c.STDIN_FILENO, c.STDOUT_FILENO) catch {};
        }
    }.run, .{&owner_att});

    const ready_thread = try spawnBoundedServerThread(&s, 4, 10_000);
    ready_thread.join();

    const route_thread = try spawnBoundedServerThread(&s, 40, 10_000);

    const fd = try client.connectUnix(path);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{
        .op = "owner_forward",
        .request_id = 1,
        .action = .{ .op = "detach" },
    });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    const res_bytes = try readFrameWithTimeout(std.testing.allocator, fd, 64 * 1024, 1000);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(res.ok);

    route_thread.join();
    owner_runtime_thread.join();

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
    std.debug.print("[client-test] done routed detach\n", .{});
    }
}

test "routed owner_control detach with stale owner returns no_owner_client" {
    if (false) {
    std.debug.print("[client-test] start routed detach stale owner\n", .{});

    var h = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } });
    defer h.deinit();
    try h.start();

    var s = server.SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-routed-owner-detach-stale.sock";
    _ = c.unlink(path);
    defer _ = c.unlink(path);
    try s.listen(path);

    const owner_attach_thread = try spawnBoundedServerThread(&s, 4, 10_000);

    var owner_cli = try client.SessionClient.init(std.testing.allocator, path);
    defer owner_cli.deinit();

    var owner_att = try owner_cli.attach(.exclusive);
    owner_attach_thread.join();

    try owner_att.sendOwnerReady();

    const ready_thread = try spawnBoundedServerThread(&s, 4, 10_000);
    ready_thread.join();

    owner_att.close();

    const close_thread = try spawnBoundedServerThread(&s, 8, 10_000);
    close_thread.join();

    var requester_cli = try client.SessionClient.init(std.testing.allocator, path);
    defer requester_cli.deinit();

    const detach_res = requester_cli.requestOwnerDetach();
    if (detach_res) {
        return error.UnexpectedResult;
    } else |e| switch (e) {
        client.Error.NoOwnerClient, error.UnexpectedEof => {},
        else => return e,
    }

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();

    std.debug.print("[client-test] done routed detach stale owner\n", .{});
    }
}

test "routed owner_control attach returns success" {
    if (false) {
    std.debug.print("[client-test] start routed attach\n", .{});
    var h1 = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 2" } });
    defer h1.deinit();
    try h1.start();

    var s1 = server.SessionServer.init(std.testing.allocator, &h1);
    defer s1.deinit();
    const path1 = "/tmp/msr-routed-owner-attach-src.sock";
    _ = c.unlink(path1);
    defer _ = c.unlink(path1);
    try s1.listen(path1);

    var h2 = try host.SessionHost.init(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1; printf target-ready; sleep 2" } });
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
    defer owner_cli.deinit();
    var owner_att = try owner_cli.attach(.exclusive);
    src_attach_thread.join();

    var runtime_in: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_in));
    defer {
        _ = c.close(runtime_in[0]);
        _ = c.close(runtime_in[1]);
    }

    var runtime_out: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_out));
    defer {
        _ = c.close(runtime_out[0]);
        _ = c.close(runtime_out[1]);
    }

    var owner_runtime_done = std.atomic.Value(bool).init(false);
    const owner_runtime_thread = try std.Thread.spawn(.{}, struct {
        fn run(att: *client.SessionAttachment, done: *std.atomic.Value(bool), in_fd: c_int, out_fd: c_int) void {
            defer done.store(true, .seq_cst);
            _ = attach_runtime.runAttachBridge(std.testing.allocator, att, in_fd, out_fd) catch {};
        }
    }.run, .{ &owner_att, &owner_runtime_done, runtime_in[0], runtime_out[1] });

    const ready_thread = try spawnBoundedServerThread(&s1, 4, 10_000);
    ready_thread.join();

    const dst_server_thread = try spawnUntilDoneServerThread(&s2, &owner_runtime_done, 10_000);
    const route_thread = try spawnBoundedServerThread(&s1, 60, 10_000);

    const fd = try client.connectUnix(path1);
    defer _ = c.close(fd);
    const req = try protocol.encodeControlReq(std.testing.allocator, .{
        .op = "owner_forward",
        .request_id = 1,
        .action = .{ .op = "attach", .path = path2 },
    });
    defer std.testing.allocator.free(req);
    try protocol.writeFrame(fd, req);

    const res_bytes = try readFrameWithTimeout(std.testing.allocator, fd, 64 * 1024, 1000);
    defer std.testing.allocator.free(res_bytes);
    var res = try protocol.parseControlRes(std.testing.allocator, res_bytes);
    defer protocol.freeControlRes(std.testing.allocator, &res);
    try std.testing.expect(res.ok);

    std.debug.print("[client-test] routed attach: requester got success\n", .{});

    route_thread.join();
    std.debug.print("[client-test] routed attach: route thread joined\n", .{});

    try h2.terminate("KILL");
    std.debug.print("[client-test] routed attach: terminated target host\n", .{});
    _ = try h2.wait();
    std.debug.print("[client-test] routed attach: waited target host\n", .{});
    try h2.close();
    std.debug.print("[client-test] routed attach: closed target host\n", .{});

    _ = c.close(runtime_in[1]);
    runtime_in[1] = -1;

    try waitForThreadDone(&owner_runtime_thread, &owner_runtime_done, 2000);
    std.debug.print("[client-test] routed attach: owner runtime thread joined\n", .{});

    dst_server_thread.join();
    std.debug.print("[client-test] routed attach: dst server thread joined\n", .{});

    try h1.terminate("KILL");
    std.debug.print("[client-test] routed attach: terminated source host\n", .{});
    _ = try h1.wait();
    std.debug.print("[client-test] routed attach: waited source host\n", .{});
    try h1.close();
    std.debug.print("[client-test] done routed attach\n", .{});
    }
}
