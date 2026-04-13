const std = @import("std");
const host = @import("host");
const server = @import("server");
const client = @import("client");
const attach_bridge = @import("attach_bridge");
const wire = @import("session_wire");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

fn readUntilContainsFromFd(
    allocator: std.mem.Allocator,
    fd: c_int,
    needle: []const u8,
    timeout_ms: i32,
) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var elapsed: i32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 50) {
        const chunk = readBytesWithTimeout(allocator, fd, 4096, 50) catch |e| switch (e) {
            error.Timeout => continue,
            else => return e,
        };
        defer allocator.free(chunk);

        try out.appendSlice(allocator, chunk);

        if (std.mem.indexOf(u8, out.items, needle) != null) {
            return out.toOwnedSlice(allocator);
        }
    }

    return error.Timeout;
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
    }.run, .{Args{
        .srv = srv,
        .loops = loops,
        .sleep_us = sleep_us,
    }});
}

fn spawnUntilDoneServerThread(
    srv: *server.SessionServer,
    done: *std.atomic.Value(bool),
    sleep_us: u32,
) !std.Thread {
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
    }.run, .{Args{
        .srv = srv,
        .done = done,
        .sleep_us = sleep_us,
    }});
}

fn waitForThreadDone(
    thread: *const std.Thread,
    done: *std.atomic.Value(bool),
    timeout_ms: u32,
) !void {
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

fn waitReadable(fd: c_int, timeout_ms: i32) !void {
    var pfd = c.struct_pollfd{
        .fd = fd,
        .events = c.POLLIN,
        .revents = 0,
    };

    while (true) {
        const pr = c.poll(&pfd, 1, timeout_ms);
        if (pr > 0) break;
        if (pr == 0) return error.Timeout;

        const e = std.posix.errno(-1);
        if (e == .INTR) continue;
        return error.IoError;
    }

    if ((pfd.revents & c.POLLIN) != 0) return;
    if ((pfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) return error.UnexpectedEof;
    return error.IoError;
}

fn readStdoutWithTimeout(
    att: *client.SessionAttachment,
    timeout_ms: i32,
) ![]u8 {
    try waitReadable(att.fd, timeout_ms);
    return try att.readStdout();
}

fn readBytesWithTimeout(
    allocator: std.mem.Allocator,
    fd: c_int,
    max_len: usize,
    timeout_ms: i32,
) ![]u8 {
    try waitReadable(fd, timeout_ms);

    const buf = try allocator.alloc(u8, max_len);
    errdefer allocator.free(buf);

    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.IoError;
    if (n == 0) return error.UnexpectedEof;

    return allocator.realloc(buf, @intCast(n));
}

test "client status roundtrip" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 1" },
    });
    defer h.deinit();
    try h.start();

    var s = server.SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-client-status-test.sock";
    server.SessionServer.unlinkBestEffort(path);
    defer server.SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    var cli = try client.SessionClient.init(std.testing.allocator, path);
    defer cli.deinit();

    const th = try spawnBoundedServerThread(&s, 4, 20_000);
    const st = try cli.status();
    th.join();

    try std.testing.expect(st == .running);

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "client attach write read detach roundtrip" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read line; printf 'got:%s' \"$line\"; sleep 1" },
    });
    defer h.deinit();
    try h.start();

    var s = server.SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-client-attach-test.sock";
    server.SessionServer.unlinkBestEffort(path);
    defer server.SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    var cli = try client.SessionClient.init(std.testing.allocator, path);
    defer cli.deinit();

    const th = try spawnBoundedServerThread(&s, 16, 20_000);

    var att = try cli.attach(.exclusive);
    defer att.close();

    try att.write("hello from client\n");

    var collected = std.ArrayList(u8){};
    defer collected.deinit(std.testing.allocator);

    const needle = "got:hello from client";
    const deadline_iters: usize = 20;

    var i: usize = 0;
    while (i < deadline_iters) : (i += 1) {
        const chunk = readStdoutWithTimeout(&att, 1000) catch |e| switch (e) {
            error.Timeout => break,
            else => return e,
        };
        defer std.testing.allocator.free(chunk);

        try collected.appendSlice(std.testing.allocator, chunk);

        if (std.mem.indexOf(u8, collected.items, needle) != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, collected.items, needle) != null);

    try att.detach();
    th.join();

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "client routed owner detach returns success" {
    var h = try host.PtyChildHost.init(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 2" },
    });
    defer h.deinit();
    try h.start();

    var s = server.SessionServer.init(std.testing.allocator, &h);
    defer s.deinit();

    const path = "/tmp/msr-client-routed-detach-test.sock";
    server.SessionServer.unlinkBestEffort(path);
    defer server.SessionServer.unlinkBestEffort(path);
    try s.listen(path);

    const owner_attach_thread = try spawnBoundedServerThread(&s, 4, 10_000);

    var owner_cli = try client.SessionClient.init(std.testing.allocator, path);
    defer owner_cli.deinit();

    var owner_att = try owner_cli.attach(.exclusive);
    defer owner_att.close();

    owner_attach_thread.join();

    var runtime_in: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_in));
    defer {
        if (runtime_in[0] >= 0) _ = c.close(runtime_in[0]);
        if (runtime_in[1] >= 0) _ = c.close(runtime_in[1]);
    }

    var runtime_out: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_out));
    defer {
        if (runtime_out[0] >= 0) _ = c.close(runtime_out[0]);
        if (runtime_out[1] >= 0) _ = c.close(runtime_out[1]);
    }

    var owner_runtime_done = std.atomic.Value(bool).init(false);
    const owner_runtime_thread = try std.Thread.spawn(.{}, struct {
        fn run(
            att: *client.SessionAttachment,
            done: *std.atomic.Value(bool),
            in_fd: c_int,
            out_fd: c_int,
        ) void {
            defer done.store(true, .seq_cst);
            _ = attach_bridge.runAttachBridge(std.testing.allocator, att, in_fd, out_fd) catch {};
        }
    }.run, .{ &owner_att, &owner_runtime_done, runtime_in[0], runtime_out[1] });

    const ready_thread = try spawnBoundedServerThread(&s, 8, 10_000);
    ready_thread.join();

    try std.testing.expect(!owner_runtime_done.load(.seq_cst));

    var server_done = std.atomic.Value(bool).init(false);
    const src_server_thread = try spawnUntilDoneServerThread(&s, &server_done, 10_000);

    var requester_cli = try client.SessionClient.init(std.testing.allocator, path);
    defer requester_cli.deinit();

    try requester_cli.requestOwnerDetach();

    try waitForThreadDone(&owner_runtime_thread, &owner_runtime_done, 2000);

    server_done.store(true, .seq_cst);
    src_server_thread.join();

    try h.terminate("KILL");
    _ = try h.wait();
    try h.close();
}

test "client routed owner attach switches bridge attachment" {
    var h1 = try host.PtyChildHost.init(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 2" },
    });
    defer h1.deinit();
    try h1.start();

    var s1 = server.SessionServer.init(std.testing.allocator, &h1);
    defer s1.deinit();

    const path1 = "/tmp/msr-client-routed-attach-src.sock";
    server.SessionServer.unlinkBestEffort(path1);
    defer server.SessionServer.unlinkBestEffort(path1);
    try s1.listen(path1);

    var h2 = try host.PtyChildHost.init(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 1; printf target-ready; sleep 3" },
    });
    defer h2.deinit();
    try h2.start();

    var s2 = server.SessionServer.init(std.testing.allocator, &h2);
    defer s2.deinit();

    const path2 = "/tmp/msr-client-routed-attach-dst.sock";
    server.SessionServer.unlinkBestEffort(path2);
    defer server.SessionServer.unlinkBestEffort(path2);
    try s2.listen(path2);

    const src_attach_thread = try spawnBoundedServerThread(&s1, 4, 10_000);

    var owner_cli = try client.SessionClient.init(std.testing.allocator, path1);
    defer owner_cli.deinit();

    var owner_att = try owner_cli.attach(.exclusive);
    defer owner_att.close();

    src_attach_thread.join();

    var runtime_in: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_in));
    defer {
        if (runtime_in[0] >= 0) _ = c.close(runtime_in[0]);
        if (runtime_in[1] >= 0) _ = c.close(runtime_in[1]);
    }

    var runtime_out: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_out));
    defer {
        if (runtime_out[0] >= 0) _ = c.close(runtime_out[0]);
        if (runtime_out[1] >= 0) _ = c.close(runtime_out[1]);
    }

    var owner_runtime_done = std.atomic.Value(bool).init(false);
    const owner_runtime_thread = try std.Thread.spawn(.{}, struct {
        fn run(
            att: *client.SessionAttachment,
            done: *std.atomic.Value(bool),
            in_fd: c_int,
            out_fd: c_int,
        ) void {
            defer done.store(true, .seq_cst);
            _ = attach_bridge.runAttachBridge(std.testing.allocator, att, in_fd, out_fd) catch {};
        }
    }.run, .{ &owner_att, &owner_runtime_done, runtime_in[0], runtime_out[1] });

    const ready_thread = try spawnBoundedServerThread(&s1, 8, 10_000);
    ready_thread.join();

    try std.testing.expect(!owner_runtime_done.load(.seq_cst));

    var src_server_done = std.atomic.Value(bool).init(false);
    var dst_server_done = std.atomic.Value(bool).init(false);

    const src_server_thread = try spawnUntilDoneServerThread(&s1, &src_server_done, 10_000);
    const dst_server_thread = try spawnUntilDoneServerThread(&s2, &dst_server_done, 10_000);

    var requester_cli = try client.SessionClient.init(std.testing.allocator, path1);
    defer requester_cli.deinit();

    try requester_cli.requestOwnerAttach(path2);

    const switched_output = try readUntilContainsFromFd(
        std.testing.allocator,
        runtime_out[0],
        "target-ready",
        3000,
    );
    defer std.testing.allocator.free(switched_output);

    try std.testing.expect(std.mem.indexOf(u8, switched_output, "target-ready") != null);

    try h2.terminate("KILL");
    _ = try h2.wait();
    try h2.close();

    try waitForThreadDone(&owner_runtime_thread, &owner_runtime_done, 3000);

    src_server_done.store(true, .seq_cst);
    dst_server_done.store(true, .seq_cst);
    src_server_thread.join();
    dst_server_thread.join();

    try h1.terminate("KILL");
    _ = try h1.wait();
    try h1.close();
}

test "client attachment readMessage sees owner request frame" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    try wire.writeMessage(std.testing.allocator, fds[1], .{
        .owner_req = .{
            .request_id = 9,
            .action = .detach,
        },
    });

    var att = client.SessionAttachment{
        .allocator = std.testing.allocator,
        .fd = fds[0],
    };

    const req = try att.readOwnerRequest();
    defer {
        var owned = req;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(u32, 9), req.request_id);
    switch (req.action) {
        .detach => {},
        else => return error.TestUnexpectedResult,
    }
}

// test "client large paste with concurrent redraw output does not deadlock" {
//     const paste_size: usize = 2 * 128 * 1024;
//
//     var h = try host.PtyChildHost.init(std.testing.allocator, .{
//         .argv = &.{
//             "/bin/sh",
//             "-c",
//             \\stty raw -echo
//             \\(
//             \\  i=0
//             \\  while [ "$i" -lt 100 ]; do
//             \\    printf '\033[H\033[2Jframe:%04d\r\n' "$i"
//             \\    i=$((i + 1))
//             \\  done
//             \\) &
//             \\bg=$!
//             \\bytes=$(dd bs=4096 count=512 status=none | wc -c | tr -d ' ')
//             \\wait "$bg"
//             \\printf 'BYTES:%s\n' "$bytes"
//             ,
//         },
//     });
//     defer h.deinit();
//     try h.start();
//
//     var s = server.SessionServer.init(std.testing.allocator, &h);
//     defer s.deinit();
//
//     const path = "/tmp/msr-client-large-paste-test.sock";
//     server.SessionServer.unlinkBestEffort(path);
//     defer server.SessionServer.unlinkBestEffort(path);
//     try s.listen(path);
//
//     const attach_thread = try spawnBoundedServerThread(&s, 8, 10_000);
//
//     var cli = try client.SessionClient.init(std.testing.allocator, path);
//     defer cli.deinit();
//
//     var att = try cli.attach(.exclusive);
//     defer att.close();
//
//     attach_thread.join();
//
//     var runtime_in: [2]c_int = undefined;
//     try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_in));
//     defer {
//         if (runtime_in[0] >= 0) _ = c.close(runtime_in[0]);
//         if (runtime_in[1] >= 0) _ = c.close(runtime_in[1]);
//     }
//
//     var runtime_out: [2]c_int = undefined;
//     try std.testing.expectEqual(@as(c_int, 0), c.pipe(&runtime_out));
//     defer {
//         if (runtime_out[0] >= 0) _ = c.close(runtime_out[0]);
//         if (runtime_out[1] >= 0) _ = c.close(runtime_out[1]);
//     }
//
//     var owner_runtime_done = std.atomic.Value(bool).init(false);
//     const owner_runtime_thread = try std.Thread.spawn(.{}, struct {
//         fn run(
//             att_inner: *client.SessionAttachment,
//             done: *std.atomic.Value(bool),
//             in_fd: c_int,
//             out_fd: c_int,
//         ) void {
//             defer done.store(true, .seq_cst);
//             _ = attach_bridge.runAttachBridge(std.testing.allocator, att_inner, in_fd, out_fd) catch {};
//         }
//     }.run, .{ &att, &owner_runtime_done, runtime_in[0], runtime_out[1] });
//
//     var server_done = std.atomic.Value(bool).init(false);
//     const server_thread = try spawnUntilDoneServerThread(&s, &server_done, 1_000);
//
//     var writer_done = std.atomic.Value(bool).init(false);
//     const writer_thread = try std.Thread.spawn(.{}, struct {
//         fn run(done: *std.atomic.Value(bool), fd: c_int, total: usize) void {
//             defer done.store(true, .seq_cst);
//             defer _ = c.close(fd);
//
//             var buf: [16 * 1024]u8 = [_]u8{'x'} ** (16 * 1024);
//             var sent: usize = 0;
//
//             while (sent < total) {
//                 const want = @min(buf.len, total - sent);
//                 var off: usize = 0;
//
//                 while (off < want) {
//                     const n = c.write(fd, buf[off..want].ptr, want - off);
//                     if (n < 0) {
//                         const e = std.posix.errno(-1);
//                         if (e == .INTR) continue;
//                         return;
//                     }
//                     if (n == 0) return;
//                     off += @intCast(n);
//                 }
//
//                 sent += want;
//             }
//         }
//     }.run, .{ &writer_done, runtime_in[1], paste_size });
//
//     runtime_in[1] = -1;
//
//     const expected = try std.fmt.allocPrint(std.testing.allocator, "BYTES:{d}", .{paste_size});
//     defer std.testing.allocator.free(expected);
//
//     const output = try readUntilContainsFromFd(
//         std.testing.allocator,
//         runtime_out[0],
//         expected,
//         20_000,
//     );
//
//     defer std.testing.allocator.free(output);
//
//     try std.testing.expect(std.mem.indexOf(u8, output, "frame:") != null);
//     try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
//
//     try waitForThreadDone(&writer_thread, &writer_done, 5_000);
//     try waitForThreadDone(&owner_runtime_thread, &owner_runtime_done, 5_000);
//
//     server_done.store(true, .seq_cst);
//     server_thread.join();
//
//     _ = try h.wait();
//     try h.close();
// }
