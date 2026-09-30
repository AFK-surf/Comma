#!/usr/bin/env bash
set -euo pipefail

grafana_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
terraform_root="$grafana_root/terraform"

if ! command -v terraform >/dev/null; then
  echo "SKIP: terraform is unavailable; CI runs the workspace guard E2E with Terraform 1.13.3"
  exit 0
fi

terraform -chdir="$terraform_root" test -no-color

scratch_stdout=$(mktemp "${TMPDIR:-/tmp}/comma-grafana-scratch.stdout.XXXXXX")
scratch_stderr=$(mktemp "${TMPDIR:-/tmp}/comma-grafana-scratch.stderr.XXXXXX")
trap 'rm -f "$scratch_stdout" "$scratch_stderr"' EXIT

set +e
TF_WORKSPACE=scratch terraform -chdir="$terraform_root" test -no-color \
  >"$scratch_stdout" 2>"$scratch_stderr"
scratch_status=$?
set -e

[[ "$scratch_status" -ne 0 ]] || {
  echo "non-default Terraform workspace unexpectedly passed" >&2
  exit 1
}
grep -Fq "Only the default Terraform workspace" "$scratch_stderr" || {
  cat "$scratch_stderr" >&2
  echo "non-default workspace failed for the wrong reason" >&2
  exit 1
}

echo "PASS: Grafana Terraform rejects non-default workspaces before resource planning"
