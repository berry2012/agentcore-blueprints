#!/usr/bin/env python3
"""
invoke-agent.py
-----------------------------------------------------------------------------
Invoke the private TechEventsFinder agent and prove the end-to-end path:

    you --(InvokeAgentRuntime, SigV4)--> AgentCore Runtime (private VPC)
                                             |
                                 (Bedrock VPC endpoint) reason
                                             |
                          (Gateway VPC endpoint) web-search tool  --> live web

The agent runs with NO internet or NAT route. Every hop it makes is over a VPC
interface endpoint. This script only calls the AgentCore data-plane
InvokeAgentRuntime API; the privacy guarantee is about the agent's egress, not
about where you run this script from.

Requires only boto3/botocore and the standard library.

Usage:
    python3 scripts/invoke-agent.py
    python3 scripts/invoke-agent.py --prompt "Find AI conferences in Europe this autumn"
    python3 scripts/invoke-agent.py --session-id my-session-123
    python3 scripts/invoke-agent.py --raw
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import uuid
from typing import Any

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:  # pragma: no cover
    sys.exit("ERROR: boto3 not importable.\n       Install with: python3 -m pip install boto3")

DEFAULT_PROMPT = "Find upcoming AWS and cloud computing conferences, with dates and locations."

_COLOR = sys.stdout.isatty()


def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _COLOR else text


def step(msg: str) -> None:
    print(_c("1;36", msg))


def ok(msg: str) -> None:
    print(_c("1;32", msg))


def err(msg: str) -> None:
    sys.stdout.flush()
    print(_c("1;31", msg), file=sys.stderr)
    sys.stderr.flush()


def terraform_outputs() -> dict[str, Any]:
    """Read `terraform output -json` from the repo root (parent of scripts/)."""
    root = pathlib.Path(__file__).resolve().parent.parent
    try:
        proc = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {}
    if proc.returncode != 0:
        return {}
    try:
        raw = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}
    return {k: v.get("value") for k, v in raw.items()}


def region_from_arn(arn: str) -> str | None:
    parts = arn.split(":")
    return parts[3] if len(parts) > 3 and parts[3] else None


def parse_payload(raw: bytes) -> Any:
    """InvokeAgentRuntime returns a streaming body; join and JSON-decode it."""
    text = raw.decode("utf-8", errors="replace").strip()
    if not text:
        return None
    # The agent may return JSON, or SSE frames for a streaming response.
    if text.startswith(("{", "[")):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text
    frames = [line[len("data:") :].strip() for line in text.splitlines() if line.startswith("data:")]
    if frames:
        try:
            return json.loads(frames[-1])
        except json.JSONDecodeError:
            return frames[-1]
    return text


def build_parser(tf: dict[str, Any]) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Invoke the private TechEventsFinder AgentCore runtime.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--prompt", "-p", default=DEFAULT_PROMPT, help="Prompt for the agent.")
    p.add_argument("--arn", default=tf.get("agent_runtime_arn"), help="Agent runtime ARN.")
    p.add_argument("--region", default=None, help="AWS Region of the runtime.")
    p.add_argument("--qualifier", default="DEFAULT", help="Runtime endpoint qualifier.")
    p.add_argument("--session-id", default=None, help="Runtime session id (defaults to a random one).")
    p.add_argument("--profile", default=None, help="AWS profile to use.")
    p.add_argument("--raw", action="store_true", help="Dump the raw response payload.")
    return p


def main() -> int:
    tf = terraform_outputs()
    args = build_parser(tf).parse_args()

    if not args.arn:
        err("ERROR: could not determine the agent runtime ARN.")
        err("       Run `terraform apply` first, or pass --arn explicitly.")
        return 2

    region = args.region or region_from_arn(args.arn)
    session = boto3.Session(profile_name=args.profile, region_name=region)
    region = region or session.region_name
    if not region:
        err("ERROR: could not determine the Region. Pass --region.")
        return 2

    # A runtime session id must be reasonably long; generate one if not given.
    session_id = args.session_id or f"techevents-{uuid.uuid4().hex}"

    client = session.client("bedrock-agentcore", region_name=region)

    step("==> 1/2  Invoking the private agent (InvokeAgentRuntime)")
    print(f"    runtime : {args.arn}")
    print(f"    region  : {region}")
    print(f"    session : {session_id}")
    print(f"    prompt  : {args.prompt}")
    print()

    try:
        resp = client.invoke_agent_runtime(
            agentRuntimeArn=args.arn,
            qualifier=args.qualifier,
            runtimeSessionId=session_id,
            contentType="application/json",
            accept="application/json",
            payload=json.dumps({"prompt": args.prompt}).encode("utf-8"),
        )
    except (ClientError, BotoCoreError) as exc:
        err(f"    InvokeAgentRuntime failed: {exc}")
        err("    Common causes: the runtime is still CREATING, the caller lacks")
        err("    bedrock-agentcore:InvokeAgentRuntime, or the agent crashed at startup")
        err("    (check /aws/bedrock-agentcore/runtimes/ logs in CloudWatch).")
        return 1

    body = resp.get("response")
    raw = body.read() if hasattr(body, "read") else (body or b"")
    payload = parse_payload(raw if isinstance(raw, bytes) else bytes(raw))

    print()
    step("==> 2/2  Verdict")
    line = "-" * 63
    print(line)

    if isinstance(payload, dict) and payload.get("error"):
        err("FAIL  The agent ran but reported an error reaching the Gateway/model.")
        err(f"      gateway_status: {payload.get('gateway_status')}")
        err(f"      error: {payload.get('error')}")
        print(line)
        if args.raw:
            print(json.dumps(payload, indent=2))
        return 1

    answer = None
    if isinstance(payload, dict):
        answer = payload.get("response")

    if answer:
        ok("PASS  The private agent answered using the Web Search Gateway.")
        if isinstance(payload, dict) and payload.get("tools_available"):
            print(f"      tools: {', '.join(payload['tools_available'])}")
        print(line)
        print()
        step("Agent response:")
        print(answer)
    else:
        err("FAIL  The call returned no agent response.")
        print(line)
        if args.raw or not isinstance(payload, dict):
            print(json.dumps(payload, indent=2) if isinstance(payload, (dict, list)) else str(payload))
        return 1

    print()
    if args.raw:
        step("Raw payload:")
        print(json.dumps(payload, indent=2) if isinstance(payload, (dict, list)) else str(payload))

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
