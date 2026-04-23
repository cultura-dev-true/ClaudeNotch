#!/usr/bin/env python3
"""
Phase 0/1 probe hook for ClaudeNotch.

Run as a PreToolUse hook via ~/.claude/settings.json. Every tool call by any
Claude Code instance (Desktop or CLI) is appended to LOG_PATH; the hook itself
returns an empty JSON object, meaning it does not override Claude's default
permission flow.

Validated so far (April 2026, Claude Code Desktop):
- Hooks registered in ~/.claude/settings.json DO fire for Desktop sessions,
  not just the CLI.
- Returning {"hookSpecificOutput": {"permissionDecision": "allow"}} from this
  script bypasses the native permission prompt and executes the tool.
- Returning {"hookSpecificOutput": {"permissionDecision": "deny",
  "permissionDecisionReason": "..."}} blocks the tool and surfaces the reason
  text to the user.
- The env variable CLAUDECODE is NOT exposed to the hook process, so it
  cannot be used to tell CLI and Desktop apart.

This file will be replaced in phase 2 by a version that forwards events over
a Unix socket to the Swift app and awaits the user's decision.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime

LOG_PATH = "/tmp/claude-notch-test.log"


def main() -> int:
    raw_payload = sys.stdin.read()
    timestamp = datetime.now().isoformat(timespec="seconds")

    with open(LOG_PATH, "a", encoding="utf-8") as log:
        log.write(f"[{timestamp}] {raw_payload}\n")

    # Empty hookSpecificOutput → no override; Claude's default flow runs.
    sys.stdout.write(json.dumps({}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
