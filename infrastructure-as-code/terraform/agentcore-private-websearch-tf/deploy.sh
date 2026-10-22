#!/usr/bin/env bash
#
# deploy.sh — provision the private AgentCore Web Search sample.
#
# Validates the environment (including Docker + ARM64 buildx, needed to build
# the agent image), initializes Terraform, shows a plan, applies it, then prints
# the outputs and the command that invokes the private agent.
#
# Usage:
#   ./deploy.sh              # interactive: review the plan before applying
#   ./deploy.sh --yes        # non-interactive (CI)
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

AUTO_APPROVE=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && AUTO_APPROVE=1

say()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# ─── 1. Validate the environment ─────────────────────────────────────────────
say "==> 1/5  Validating environment"

command -v terraform >/dev/null || fail "terraform not found. Install >= 1.6."

TF_VER=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo "0.0.0")
python3 - "$TF_VER" <<'PY' || fail "Terraform >= 1.6 required (found $TF_VER)."
import sys
v = tuple(int(x) for x in sys.argv[1].split(".")[:3])
sys.exit(0 if v >= (1, 6, 0) else 1)
PY
echo "    terraform  : $TF_VER"

command -v python3 >/dev/null || fail "python3 not found (needed by the test script)."
echo "    python3    : $(python3 -V 2>&1 | awk '{print $2}')"

python3 -c "import botocore" 2>/dev/null \
  || fail "botocore not importable. Install with: pip install boto3"
echo "    botocore   : present"

command -v docker >/dev/null || fail "docker not found. Needed to build the agent's ARM64 image."
docker info >/dev/null 2>&1 || fail "Docker daemon not running. Start Docker and retry."
docker buildx version >/dev/null 2>&1 \
  || fail "docker buildx not available. It is required to build the linux/arm64 agent image."
echo "    docker     : $(docker --version | awk '{print $3}' | tr -d ',') (buildx present)"

command -v aws >/dev/null || fail "AWS CLI not found."
CALLER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) \
  || fail "No valid AWS credentials. Configure a profile or run 'aws configure'."
echo "    identity   : $CALLER"

REGION=$(python3 - <<'PY'
import re, pathlib
m = re.search(r'default\s*=\s*"([^"]+)"',
              re.split(r'variable\s+"region"', pathlib.Path("variables.tf").read_text())[1])
print(m.group(1) if m else "us-east-1")
PY
)
echo "    region     : $REGION (override with -var region=...)"
echo

# ─── 2. Initialize ───────────────────────────────────────────────────────────
say "==> 2/5  terraform init"
terraform init -input=false
echo

# ─── 3. Validate the configuration ───────────────────────────────────────────
say "==> 3/5  terraform validate"
terraform validate
ok "    configuration is valid"
echo

# ─── 4. Plan ─────────────────────────────────────────────────────────────────
say "==> 4/5  terraform plan"
terraform plan -input=false -out=tfplan
echo

if [[ "$AUTO_APPROVE" -eq 0 ]]; then
  read -r -p "Apply this plan? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { rm -f tfplan; fail "Aborted."; }
fi

# ─── 5. Apply ────────────────────────────────────────────────────────────────
say "==> 5/5  terraform apply"
terraform apply -input=false tfplan
rm -f tfplan
echo

ok "=============================================="
ok " Deployed"
ok "=============================================="
echo
terraform output
echo
say "Invoke the private agent:"
echo "  python3 scripts/invoke-agent.py --prompt \"Find upcoming AWS and cloud tech conferences\""
echo
say "Tear down when finished:"
echo "  ./destroy.sh"
