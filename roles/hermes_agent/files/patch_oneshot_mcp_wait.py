#!/usr/bin/env python3
"""Idempotently patch hermes_cli/oneshot.py to wait for MCP discovery.

Upstream bug (hermes-agent v0.16.0): the one-shot (`hermes -z`) path starts
MCP discovery on a background thread but snapshots the agent's tool list
~1s in without calling wait_for_mcp_discovery(), and never refreshes it.
On a Pi 4 the stdio npx server takes ~4-8s to register, so MCP tools never
appear in CLI payloads. Gateway/cron/TUI entry points do their own blocking
discovery and are unaffected.

Exit codes: 0 = patched or already applied (prints which), 1 = anchor not
found (upstream changed — re-evaluate whether the patch is still needed).
Evidence: smart-assistant repo, debugging/perplexity-mcp-tool-calling.md.
"""
import sys

ONESHOT = sys.argv[1] if len(sys.argv) > 1 else (
    "/home/hermes/.hermes/hermes-agent/hermes_cli/oneshot.py"
)

ANCHOR = """    response: Optional[str] = None
    failure: BaseException | None = None
    try:
        with redirect_stdout(devnull), redirect_stderr(devnull):"""

PATCHED = """    response: Optional[str] = None
    failure: BaseException | None = None
    try:
        from hermes_cli.mcp_startup import wait_for_mcp_discovery
        wait_for_mcp_discovery(timeout=20.0)
    except Exception:
        pass
    try:
        with redirect_stdout(devnull), redirect_stderr(devnull):"""

src = open(ONESHOT).read()

if "wait_for_mcp_discovery" in src:
    print("already-applied")
    sys.exit(0)

if src.count(ANCHOR) != 1:
    print("anchor-missing: upstream oneshot.py changed; re-evaluate the patch")
    sys.exit(1)

open(ONESHOT, "w").write(src.replace(ANCHOR, PATCHED))

import py_compile
py_compile.compile(ONESHOT, doraise=True)
print("patched")
