#!/usr/bin/env python3
"""PreToolUse guard: block edits to generated build outputs (MoveBreak.app/, build/).

Standard library only. Fail-open: any malformed input or error exits 0 so a hook
bug can never wedge a session. Exit 2 (with a stderr message) blocks the tool call.
"""
import json
import os
import sys

PROTECTED = ('MoveBreak.app', 'build')


def blocked(payload):
    tool_input = payload.get('tool_input') or {}
    target = tool_input.get('file_path') or tool_input.get('notebook_path')
    if not isinstance(target, str) or not target:
        return False
    project = os.path.realpath(os.environ.get('CLAUDE_PROJECT_DIR') or os.getcwd())
    if not os.path.isabs(target):
        target = os.path.join(project, target)
    relative = os.path.relpath(os.path.realpath(target), project)
    first = relative.split(os.sep, 1)[0]
    return first in PROTECTED


def main():
    try:
        if blocked(json.load(sys.stdin)):
            sys.stderr.write(
                'Blocked: MoveBreak.app/ and build/ are generated outputs overwritten by the build. '
                'Edit Sources/ and rebuild with ./scripts/build_app.sh.\n')
            return 2
    except Exception:
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
