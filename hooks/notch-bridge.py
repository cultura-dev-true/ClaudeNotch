#!/usr/bin/env python3
"""
Phase 2.2 bridge hook for ClaudeNotch.

Forwards each PreToolUse event to the Swift app over /tmp/claude-notch.sock
and blocks until Swift sends back the JSON that Claude Code should see as
this hook's stdout. Swift is the source of truth for the decision; this
script is essentially a dumb pipe with a safety fallback.

Behavior:
- Swift app not running → silently write {} (no override → Claude's default flow).
- Connect fast (0.2s); read up to RESPONSE_TIMEOUT_SEC for the decision.
- If read times out → write {} (safe fallback; Claude still uses default flow).
- Any Swift response (incl. {}) is piped verbatim to stdout.
"""

from __future__ import annotations

import socket
import sys
from datetime import datetime

LOG_PATH = "/tmp/claude-notch-test.log"
SOCKET_PATH = "/tmp/claude-notch.sock"
CONNECT_TIMEOUT_SEC = 0.2
RESPONSE_TIMEOUT_SEC = 35  # slightly longer than Swift's 30s pending timeout


def forward_to_notch(payload: str) -> tuple[str, bytes]:
    """Send payload, wait for Swift's response. Returns (status, bytes)."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(CONNECT_TIMEOUT_SEC)
        try:
            sock.connect(SOCKET_PATH)
        except FileNotFoundError:
            return "no-socket", b""
        except ConnectionRefusedError:
            return "refused", b""
        except socket.timeout:
            return "connect-timeout", b""
        except OSError as error:
            return f"oserror-connect:{error.errno}", b""

        try:
            sock.sendall(payload.encode("utf-8"))
            sock.shutdown(socket.SHUT_WR)
        except OSError as error:
            return f"oserror-send:{error.errno}", b""

        # Wait for Swift's decision.
        sock.settimeout(RESPONSE_TIMEOUT_SEC)
        buffer = bytearray()
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buffer.extend(chunk)
        except socket.timeout:
            return "recv-timeout", bytes(buffer)
        except OSError as error:
            return f"oserror-recv:{error.errno}", bytes(buffer)

        return "ok", bytes(buffer)
    finally:
        sock.close()


def main() -> int:
    raw_payload = sys.stdin.read()
    timestamp = datetime.now().isoformat(timespec="seconds")

    if raw_payload:
        status, response_bytes = forward_to_notch(raw_payload)
    else:
        status, response_bytes = "empty-input", b""

    response_str = response_bytes.decode("utf-8", "replace")
    preview = response_str if len(response_str) <= 200 else response_str[:200] + "..."
    with open(LOG_PATH, "a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] bridge={status} resp={preview} {raw_payload}\n")

    # Pipe Swift's response verbatim, or fall back to empty {} if nothing came.
    sys.stdout.write(response_str if response_bytes else "{}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
