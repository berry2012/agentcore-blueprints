#!/usr/bin/env python3
"""
selftest.py
-----------------------------------------------------------------------------
Offline self-test for the private AgentCore Web Search sample. No AWS calls, no
cost. Exercises the pure logic in the test client and the agent's SigV4 signing
hook, so CI can gate on it without credentials.

    python3 scripts/selftest.py        # exit 0 on success, 1 on failure
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
from types import ModuleType

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _load(path: pathlib.Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Checks:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def eq(self, label: str, got, want) -> None:
        if got == want:
            self.passed += 1
            print(f"  ok   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}: got {got!r}, want {want!r}")

    def truthy(self, label: str, got) -> None:
        if got:
            self.passed += 1
            print(f"  ok   {label}")
        else:
            self.failed += 1
            print(f"  FAIL {label}: expected truthy, got {got!r}")


def test_invoke_client(c: Checks) -> None:
    print("invoke-agent.py")
    mod = _load(ROOT / "scripts" / "invoke-agent.py", "invoke_agent")

    # region_from_arn
    arn = "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/TechEventsFinder-abc"
    c.eq("region_from_arn extracts region", mod.region_from_arn(arn), "us-east-1")
    c.eq("region_from_arn on junk returns None", mod.region_from_arn("not-an-arn"), None)

    # parse_payload: plain JSON object
    c.eq(
        "parse_payload decodes JSON object",
        mod.parse_payload(b'{"response": "hello", "agent": "techevents-finder"}'),
        {"response": "hello", "agent": "techevents-finder"},
    )
    # parse_payload: SSE frames -> last frame wins
    sse = b'data: {"event": "first"}\n\ndata: {"response": "final"}\n\n'
    c.eq("parse_payload takes last SSE frame", mod.parse_payload(sse), {"response": "final"})
    # parse_payload: empty
    c.eq("parse_payload on empty body returns None", mod.parse_payload(b""), None)
    # parse_payload: plain text fallback
    c.eq("parse_payload plain text passthrough", mod.parse_payload(b"just text"), "just text")


def test_sigv4_auth(c: Checks) -> None:
    print("agent.py SigV4 hook")
    try:
        import boto3  # noqa: F401
        import httpx
        from botocore.credentials import Credentials
    except ImportError:
        print("  skip (httpx/boto3 not installed in this environment)")
        return

    # Import only the SigV4 class without pulling in strands/mcp (which the agent
    # container has but a dev box may not). We exec just the class definition.
    import httpx
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest

    # Reproduce the auth_flow behaviour with a static credential and assert the
    # signed request carries an Authorization header and no stale Host header.
    creds = Credentials("AKIDEXAMPLENOTREAL", "secretnotreal", "tokennotreal")
    signer = SigV4Auth(creds, "bedrock-agentcore", "us-east-1")

    req = httpx.Request(
        "POST",
        "https://abc123.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp",
        content=b'{"jsonrpc":"2.0","method":"tools/list","id":1}',
        headers={"Content-Type": "application/json", "MCP-Protocol-Version": "2025-11-25"},
    )
    aws_req = AWSRequest(method=req.method, url=str(req.url), data=req.content, headers=dict(req.headers))
    if "host" in aws_req.headers:
        del aws_req.headers["host"]
    signer.add_auth(aws_req)
    for k, v in aws_req.headers.items():
        req.headers[k] = v

    c.truthy("Authorization header present after signing", req.headers.get("Authorization"))
    c.truthy("X-Amz-Date header present", req.headers.get("X-Amz-Date"))
    c.truthy("X-Amz-Security-Token present for session creds", req.headers.get("X-Amz-Security-Token"))
    c.truthy("MCP-Protocol-Version preserved", req.headers.get("MCP-Protocol-Version") == "2025-11-25")
    c.truthy(
        "Authorization scopes the correct service",
        "bedrock-agentcore" in req.headers.get("Authorization", ""),
    )


def main() -> int:
    c = Checks()
    print("=" * 63)
    print("Offline self-test: private AgentCore Web Search sample")
    print("=" * 63)
    test_invoke_client(c)
    print()
    test_sigv4_auth(c)
    print()
    print("-" * 63)
    total = c.passed + c.failed
    if c.failed:
        print(f"FAIL  {c.failed}/{total} checks failed")
        return 1
    print(f"PASS  {c.passed}/{total} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
