"""
TechEventsFinder — a private AgentCore Runtime agent.

Packaged for Amazon Bedrock AgentCore Runtime (BYOC / HTTP protocol), deployed
in VPC mode with no internet or NAT gateway. The agent reaches two AWS services,
both over AWS PrivateLink interface endpoints:

  1. Amazon Bedrock (the reasoning model), via the bedrock-runtime endpoint.
  2. The AgentCore Web Search Gateway, via the bedrock-agentcore.gateway
     endpoint. The agent speaks MCP to the Gateway and SigV4-signs every request
     with its own execution-role credentials (the Gateway uses AWS_IAM inbound
     auth).

Runtime contract implemented here:
  - GET  /ping         -> {"status": "Healthy"}
  - POST /invocations  -> agent entry point, returns a structured JSON response
  - Port 8080

No search API keys, no third-party search engine, no public network path.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import boto3
import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient

logging.basicConfig(
    format="%(levelname)s | %(name)s | %(message)s",
    handlers=[logging.StreamHandler()],
    level=logging.INFO,
)
logger = logging.getLogger("techevents-finder")

# --- Configuration (env-driven; set by Terraform on the runtime) -------------
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
GATEWAY_MCP_URL = os.environ.get("GATEWAY_MCP_URL", "")
GATEWAY_TOOL_NAME = os.environ.get("GATEWAY_TOOL_NAME", "web-search___WebSearch")
MCP_PROTOCOL_VERSION = os.environ.get("MCP_PROTOCOL_VERSION", "2025-11-25")
CONNECT_TIMEOUT_SECONDS = float(os.environ.get("CONNECT_TIMEOUT_SECONDS", "30"))
# Inside the container AgentCore reaches the agent across the container boundary,
# so the server must bind all interfaces here. The port is never published to
# the internet: the runtime's ENIs live in private subnets and ingress is the
# AgentCore managed data path, not a published port. Governed by the runtime,
# not by this bind.
PORT = int(os.environ.get("PORT", "8080"))

SERVICE = "bedrock-agentcore"

SYSTEM_PROMPT = """You are TechEventsFinder, a focused assistant that finds upcoming
technology events — conferences, summits, meetups, hackathons, and workshops.

You have one tool: a web search tool exposed through an AgentCore Gateway. Use it
to find current, dated information; never invent event names, dates, or venues.

When answering:
- Search the web for the events the user asks about.
- Prefer events with a clear name, date, and location, and cite the source URL.
- If results are thin, say so plainly and suggest a narrower or broader query.
- Keep answers concise and scannable: a short list of events, each with date,
  location, and link."""


# --- SigV4 auth for the MCP HTTP transport -----------------------------------
class SigV4HTTPXAuth(httpx.Auth):
    """Sign each outgoing httpx request to the Gateway with SigV4.

    The Gateway uses AWS_IAM inbound auth, so every MCP request (tools/list,
    tools/call, ...) must carry a SigV4 signature from the agent's execution
    role. botocore signs the request; we copy the resulting auth headers onto
    the httpx request. Credentials are the ambient role credentials AgentCore
    injects into the runtime — there is nothing to configure or store.
    """

    requires_request_body = True

    def __init__(self, region: str) -> None:
        session = boto3.Session()
        creds = session.get_credentials()
        if creds is None:
            raise RuntimeError("No AWS credentials available to sign Gateway requests.")
        self._creds = creds
        self._region = region

    def auth_flow(self, request: httpx.Request):
        # Freeze credentials per request so a mid-flight refresh is picked up.
        frozen = self._creds.get_frozen_credentials()
        signer = SigV4Auth(frozen, SERVICE, self._region)

        body = request.content or b""
        aws_req = AWSRequest(
            method=request.method,
            url=str(request.url),
            data=body,
            headers=dict(request.headers),
        )
        # botocore recomputes the Host header from the URL; drop any inherited
        # one so the signature and the sent header agree. botocore's HTTPHeaders
        # has no .pop(), so delete by key if present.
        if "host" in aws_req.headers:
            del aws_req.headers["host"]
        signer.add_auth(aws_req)

        for key, value in aws_req.headers.items():
            request.headers[key] = value
        yield request


def _make_gateway_mcp_client() -> MCPClient:
    """Build an MCPClient that talks to the Gateway over SigV4-signed HTTP."""
    if not GATEWAY_MCP_URL:
        raise RuntimeError("GATEWAY_MCP_URL is not set; cannot reach the Web Search Gateway.")

    auth = SigV4HTTPXAuth(AWS_REGION)

    def transport():
        return streamablehttp_client(
            GATEWAY_MCP_URL,
            headers={"MCP-Protocol-Version": MCP_PROTOCOL_VERSION},
            auth=auth,
            timeout=CONNECT_TIMEOUT_SECONDS,
            sse_read_timeout=120.0,
        )

    return MCPClient(transport)


# --- Model --------------------------------------------------------------------
model = BedrockModel(
    model_id=BEDROCK_MODEL_ID,
    region_name=AWS_REGION,
    temperature=0.3,
)


def run_agent(message: str, context: str | None = None) -> dict[str, Any]:
    """Run one agent turn with the Gateway web-search tool loaded over MCP."""
    prompt = message if not context else f"Context: {context}\n\nQuestion: {message}"

    gateway_status = "connected"
    tools_available: list[str] = []
    try:
        mcp_client = _make_gateway_mcp_client()
        # The MCPClient session must stay open for the whole turn.
        with mcp_client:
            mcp_tools = mcp_client.list_tools_sync()
            tools_available = [getattr(t, "tool_name", str(t)) for t in mcp_tools]
            logger.info("Gateway tools discovered: %s", tools_available)

            agent = Agent(model=model, system_prompt=SYSTEM_PROMPT, tools=mcp_tools)
            result = agent(prompt)
            response_text = str(result)
    except Exception as exc:
        logger.exception("Gateway/agent turn failed")
        gateway_status = f"error: {exc}"
        return {
            "response": None,
            "error": str(exc),
            "agent": "techevents-finder",
            "gateway_url": GATEWAY_MCP_URL,
            "gateway_status": gateway_status,
        }

    return {
        "response": response_text,
        "model": BEDROCK_MODEL_ID,
        "agent": "techevents-finder",
        "gateway_url": GATEWAY_MCP_URL,
        "gateway_status": gateway_status,
        "tools_available": tools_available,
    }


# --- FastAPI app (AgentCore HTTP contract) ------------------------------------
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(
    title="TechEventsFinder (AgentCore, private VPC)",
    description="Finds tech events via a private AgentCore Web Search Gateway",
    version="1.0.0",
)


class InvocationRequest(BaseModel):
    prompt: str | None = None
    message: str | None = None
    input: str | None = None
    context: str | None = None


@app.get("/ping")
def ping() -> dict[str, str]:
    return {"status": "Healthy"}


@app.post("/invocations")
def invocations(request: InvocationRequest) -> dict[str, Any]:
    user_message = request.prompt or request.message or request.input
    if not user_message:
        raise HTTPException(
            status_code=400,
            detail="Request must include one of: 'prompt', 'message', or 'input'.",
        )
    try:
        return run_agent(user_message, request.context)
    except Exception as exc:
        logger.exception("Invocation failed")
        raise HTTPException(status_code=500, detail=str(exc))


if __name__ == "__main__":
    import sys

    if "--serve" in sys.argv or os.environ.get("SERVE", "").lower() in ("1", "true"):
        import uvicorn

        # See the PORT note above: all-interfaces bind inside the container is
        # the AgentCore contract; the port is not published to any network.
        uvicorn.run(app, host="0.0.0.0", port=PORT)  # nosec B104
    else:
        print("TechEventsFinder (local CLI). Type 'quit' to exit.\n")
        while True:
            try:
                user_input = input("You: ").strip()
                if user_input.lower() in ("quit", "exit", "q"):
                    break
                if not user_input:
                    continue
                out = run_agent(user_input)
                print(f"\nTechEventsFinder: {out.get('response') or out.get('error')}\n")
            except KeyboardInterrupt:
                break
