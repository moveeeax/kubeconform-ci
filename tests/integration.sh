#!/usr/bin/env bash
# integration.sh — end-to-end check of the action's orchestrator against the
# bundled examples. Requires kubeconform (and kustomize for the render case) on
# PATH; CI installs them first. Asserts valid manifests pass and invalid fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export INPUT_KUBERNETES_VERSION="${INPUT_KUBERNETES_VERSION:-1.30}"

fail() { echo "integration: FAIL — $1" >&2; exit 1; }

echo "== case 1: valid manifests must pass =="
if ! INPUT_DIRS="examples/manifests" bash scripts/kubeconform-ci.sh; then
  fail "valid manifests were rejected"
fi

echo "== case 2: invalid manifest must fail =="
if INPUT_DIRS="examples/invalid" bash scripts/kubeconform-ci.sh; then
  fail "invalid manifest was accepted"
fi

echo "== case 3: invalid-count output is populated =="
out="$(mktemp)"
GITHUB_OUTPUT="$out" INPUT_DIRS="examples/invalid" bash scripts/kubeconform-ci.sh || true
grep -q 'invalid-count=1' "$out" || { cat "$out"; fail "invalid-count not reported as 1"; }
rm -f "$out"

echo "== case 4: manifests + kustomize overlay must pass =="
if command -v kustomize >/dev/null 2>&1; then
  if ! INPUT_DIRS="examples/manifests examples/kustomize" bash scripts/kubeconform-ci.sh; then
    fail "example tree with kustomize was rejected"
  fi
else
  echo "integration: kustomize absent, skipping render case"
fi

echo "integration: all cases passed ✅"
