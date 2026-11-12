#!/usr/bin/env bash
# integration.sh — end-to-end check of the action's orchestrator against the
# bundled examples. Requires kubeconform (and kustomize / helm for the render
# cases) on PATH; CI installs them first. Asserts valid manifests pass, invalid
# fail, a failing kustomize build / helm template fails with its stderr, and
# requested rendering without the tool fails instead of skipping.
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

echo "== case 5: helm chart must render and pass =="
if command -v helm >/dev/null 2>&1; then
  if ! INPUT_DIRS="examples/manifests" INPUT_HELM_CHARTS="examples/helm/web" bash scripts/kubeconform-ci.sh; then
    fail "example helm chart was rejected"
  fi
else
  echo "integration: helm absent, skipping helm render case"
fi

echo "== case 6: failing kustomize build must fail with its stderr =="
if command -v kustomize >/dev/null 2>&1; then
  log="$(mktemp)"; out="$(mktemp)"
  if GITHUB_OUTPUT="$out" INPUT_DIRS="examples/manifests tests/fixtures/render/broken-kustomize" \
    bash scripts/kubeconform-ci.sh > "$log" 2>&1; then
    cat "$log"; fail "broken kustomization passed"
  fi
  grep -q '::error file=tests/fixtures/render/broken-kustomize/kustomization.yaml' "$log" \
    || { cat "$log"; fail "no ::error annotation for the broken kustomization"; }
  grep -q 'kustomize build tests/fixtures/render/broken-kustomize failed' "$log" \
    || { cat "$log"; fail "annotation does not name the kustomize dir"; }
  grep -q 'missing-deployment.yaml' "$log" \
    || { cat "$log"; fail "kustomize stderr missing from the output"; }
  grep -q 'invalid-count=1' "$out" || { cat "$out"; fail "invalid-count not reported as 1"; }
  rm -f "$log" "$out"
else
  echo "integration: kustomize absent, skipping broken kustomization case"
fi

echo "== case 7: failing helm template must fail with its stderr =="
if command -v helm >/dev/null 2>&1; then
  log="$(mktemp)"; out="$(mktemp)"
  if GITHUB_OUTPUT="$out" INPUT_DIRS="examples/manifests" \
    INPUT_HELM_CHARTS="examples/helm/web tests/fixtures/render/broken-chart" \
    bash scripts/kubeconform-ci.sh > "$log" 2>&1; then
    cat "$log"; fail "broken helm chart passed"
  fi
  grep -q '::error file=tests/fixtures/render/broken-chart/Chart.yaml' "$log" \
    || { cat "$log"; fail "no ::error annotation for the broken chart"; }
  grep -q 'helm template broken-chart tests/fixtures/render/broken-chart failed' "$log" \
    || { cat "$log"; fail "annotation does not name the chart"; }
  grep -q 'noSuchFunction' "$log" || { cat "$log"; fail "helm stderr missing from the output"; }
  grep -q 'invalid-count=1' "$out" || { cat "$out"; fail "invalid-count not reported as 1"; }
  rm -f "$log" "$out"
else
  echo "integration: helm absent, skipping broken chart case"
fi

# PATH with kubeconform, jq and bash but no kustomize or helm.
nobin="$(mktemp -d)"
for tool in kubeconform jq bash; do
  ln -s "$(command -v "$tool")" "${nobin}/${tool}"
done
bare_path="${nobin}:/usr/bin:/bin"
if PATH="$bare_path" command -v kustomize >/dev/null 2>&1 \
  || PATH="$bare_path" command -v helm >/dev/null 2>&1; then
  echo "integration: kustomize or helm lives in /usr/bin or /bin, skipping missing-tool cases"
else
  echo "== case 8: kustomize=true without kustomize must fail =="
  if PATH="$bare_path" INPUT_DIRS="examples/kustomize" INPUT_KUSTOMIZE="true" bash scripts/kubeconform-ci.sh; then
    fail "kustomize=true passed without kustomize on PATH"
  fi

  echo "== case 9: helm-charts without helm must fail =="
  if PATH="$bare_path" INPUT_DIRS="examples/manifests" INPUT_HELM_CHARTS="examples/helm/web" bash scripts/kubeconform-ci.sh; then
    fail "helm-charts passed without helm on PATH"
  fi

  echo "== case 10: kustomize=auto without kustomize still runs =="
  if ! PATH="$bare_path" INPUT_DIRS="examples/manifests" bash scripts/kubeconform-ci.sh; then
    fail "auto mode without kustomize rejected plain manifests"
  fi
fi
rm -rf "$nobin"

echo "integration: all cases passed ✅"
