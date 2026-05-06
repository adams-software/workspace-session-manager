#!/usr/bin/env python3
import socket
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: control_client.py <socket-path> <command> [<command> ...]", file=sys.stderr)
        return 2

    path = sys.argv[1]
    commands = sys.argv[2:]

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)
    try:
        for command in commands:
            sock.sendall(command.encode("utf-8") + b"\n")
            data = b""
            while not data.endswith(b"\n"):
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
            sys.stdout.write(data.decode("utf-8", errors="replace"))
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
