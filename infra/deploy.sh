#!/usr/bin/env bash
# Two-pass deploy, run from infra/ with az and terraform logged in.
#   ./deploy.sh            pass 1: everything except the Container App (Key Vault and key, identity, environment).
#   ./deploy.sh <image>    pass 2: also the Container App, running <image> (print one with broker/publish.sh).
#                          The image is kept in image.auto.tfvars (gitignored), so later runs without an argument keep it.
# Needs policy.auto.tfvars (gateway/setup.sh) and terraform.tfvars next to this script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f policy.auto.tfvars ]] || { echo "policy.auto.tfvars missing: run gateway/setup.sh first" >&2; exit 1; }

[[ $# -eq 0 ]] || printf 'container_image = "%s"\n' "$1" > image.auto.tfvars
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve
terraform output
