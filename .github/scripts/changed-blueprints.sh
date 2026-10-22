#!/usr/bin/env bash
# List the blueprint folders a change touches, as JSON arrays for a CI matrix.
#
# Usage:
#   changed-blueprints.sh --all           every blueprint folder
#   changed-blueprints.sh <base> <head>   folders changed in base...head
#
# A blueprint folder is infrastructure-as-code/<tool>/<name>/. Folders deleted
# by the change are skipped. Changes to the CI tooling itself select every
# blueprint so tooling updates are tested against all of them. An empty, all-
# zeros, or unknown <base> (new branch, force-push) also selects every blueprint.
#
# Outputs `blueprints`, `terraform`, and `cloudformation` (compact JSON arrays)
# to $GITHUB_OUTPUT when set, and always prints them to stdout.
set -euo pipefail

TOOLS_RE='^infrastructure-as-code/(terraform|cloudformation|cdk)/[^/]+/'
CI_RE='^\.github/workflows/iac\.yml$|^\.github/scripts/|^\.tflint\.hcl$'

all_blueprints() {
  local d
  for d in infrastructure-as-code/{terraform,cloudformation,cdk}/*/; do
    [[ -d "$d" ]] && printf '%s\n' "${d%/}"
  done
  return 0
}

select_all=false
if [[ "${1:-}" == "--all" ]]; then
  select_all=true
elif [[ $# -eq 2 ]]; then
  base="$1"
  head="$2"
  if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "notice: base '${base}' is empty or not a known commit; selecting all blueprints" >&2
    select_all=true
  else
    changed="$(git diff --name-only "${base}...${head}")"
    if grep -Eq "$CI_RE" <<<"$changed"; then
      echo "notice: CI tooling changed; selecting all blueprints" >&2
      select_all=true
    fi
  fi
else
  echo "usage: $0 --all | $0 <base> <head>" >&2
  exit 2
fi

if $select_all; then
  dirs="$(all_blueprints)"
else
  dirs="$(
    grep -E "$TOOLS_RE" <<<"$changed" | cut -d/ -f1-3 | sort -u |
      while IFS= read -r d; do
        if [[ -d "$d" ]]; then printf '%s\n' "$d"; fi
      done
  )" || true
fi

to_json() {
  # Read newline-separated paths on stdin, print a compact JSON array.
  local items=()
  mapfile -t items < <(grep -v '^$' || true)
  jq -cn '$ARGS.positional' --args ${items[@]+"${items[@]}"}
}

# The three arrays are read indirectly via ${!name} in the loop below.
# shellcheck disable=SC2034
blueprints="$(to_json <<<"$dirs")"
# shellcheck disable=SC2034
terraform="$({ grep '^infrastructure-as-code/terraform/' <<<"$dirs" || true; } | to_json)"
# shellcheck disable=SC2034
cloudformation="$({ grep '^infrastructure-as-code/cloudformation/' <<<"$dirs" || true; } | to_json)"

for name in blueprints terraform cloudformation; do
  line="${name}=${!name}"
  echo "$line"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$line" >> "$GITHUB_OUTPUT"
  fi
done
