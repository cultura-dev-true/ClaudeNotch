#!/usr/bin/env python3
"""
Phase 2.1 bridge hook for ClaudeNotch.

For every PreToolUse event:
1. Append the raw payload to LOG_PATH (debug trail).
2. Best-effort forward it to the Swift app over a Unix domain socket at
   SOCKET_PATH. If the app is not running / the socket is missing, the
   forward silently fails after SOCKET_TIMEOUT_SEC and Claude Code is
   unaffected.
3. Return an empty JSON object so Claude's default permission flow runs.

Phase 2.2 will replace step 2 with a request/response exchange — the hook
will wait for the user's decision from the notch and echo it back to Claude
as `permissionDecision`.
"""

from __future__ import annotations

import json
import socket
import sys
from datetime import datetime

LOG_PATH = "/tmp/claude-notch-test.log"
SOCKET_PATH = "/tmp/claude-notch.sock"
SOCKET_TIMEOUT_SEC = 0.2


def forward_to_notch(payload: str) -> str:
    """Send payload and block briefly until the server closes its end.

    Why the read after shutdown: NWListener on macOS appears to silently drop
    connections whose client closes before the framework has pulled the new
    socket off the accept queue. Blocking here (bounded by SOCKET_TIMEOUT_SEC)
    keeps the client alive long enough for Swift to accept, read, and cancel
    the connection — at which point our recv() returns 0 bytes (EOF).
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(SOCKET_TIMEOUT_SEC)
    try:
        sock.connect(SOCKET_PATH)
        sock.sendall(payload.encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        try:
            sock.recv(1)  # blocks until server closes or timeout
        except socket.timeout:
            pass  # server was slow, but bytes were delivered
        return "sent"
    except FileNotFoundError:
        return "no-socket"
    except ConnectionRefusedError:
        return "refused"
    except socket.timeout:
        return "timeout"
    except OSError as error:
        return f"oserror:{error.errno}"
    finally:
        sock.close()


def main() -> int:
    raw_payload = sys.stdin.read()
    timestamp = datetime.now().isoformat(timespec="seconds")
    status = forward_to_notch(raw_payload) if raw_payload else "empty-input"

    with open(LOG_PATH, "a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] bridge={status} {raw_payload}\n")

    sys.stdout.write(json.dumps({}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
