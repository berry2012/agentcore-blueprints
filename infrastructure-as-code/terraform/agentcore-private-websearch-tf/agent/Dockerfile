# AgentCore Runtime requires linux/arm64 (Graviton). x86 images will not start.
FROM --platform=linux/arm64 python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .

# AgentCore HTTP contract: health check on GET /ping, invoke on POST
# /invocations, served on port 8080.
ENV PORT=8080
ENV BYPASS_TOOL_CONSENT=true

# OpenTelemetry (ADOT) configuration. Strands emits spans natively; ADOT's
# auto-instrumentation exports them to CloudWatch. OTEL_SERVICE_NAME is how the
# agent appears on the CloudWatch GenAI Observability dashboard. The AgentCore
# Runtime injects session.id and the CloudWatch exporter config at run time.
ENV OTEL_SERVICE_NAME=TechEventsFinder
ENV OTEL_PYTHON_DISTRO=aws_distro
ENV OTEL_PYTHON_CONFIGURATOR=aws_configurator

EXPOSE 8080

# Launch under opentelemetry-instrument so Strands, the Bedrock model calls, and
# the MCP/HTTP calls to the Gateway are auto-traced and spans ship to CloudWatch.
CMD ["opentelemetry-instrument", "python", "agent.py", "--serve"]
