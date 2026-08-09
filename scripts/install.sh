#!/usr/bin/env bash
# install.sh — fetch the kubeconform binary and put it on PATH for later steps.
# Runs inside the composite action. yq/helm/kustomize are only fetched when the
# corresponding feature is requested and the tool is not already available.
set -euo pipefail

ver="${KUBECONFORM_VERSION:-0.6.7}"
ver="${ver#v}"
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
esac

bindir="${HOME}/.kubeconform-ci/bin"
mkdir -p "$bindir"

if ! command -v kubeconform >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  url="https://github.com/yannh/kubeconform/releases/download/v${ver}/kubeconform-${os}-${arch}.tar.gz"
  echo "kubeconform-ci: installing kubeconform v${ver} (${os}/${arch})"
  curl -fsSL "$url" -o "${tmp}/kubeconform.tar.gz"
  tar -xzf "${tmp}/kubeconform.tar.gz" -C "$tmp" kubeconform
  install -m0755 "${tmp}/kubeconform" "${bindir}/kubeconform"
fi

if command -v yq >/dev/null 2>&1; then :; else
  # yq is optional; only fetch when missing so rendered docs can be split.
  yq_ver="4.44.3"
  url="https://github.com/mikefarah/yq/releases/download/v${yq_ver}/yq_${os}_${arch}"
  echo "kubeconform-ci: installing yq v${yq_ver}"
  curl -fsSL "$url" -o "${bindir}/yq" && chmod +x "${bindir}/yq" || echo "kubeconform-ci: yq install skipped"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bindir" >> "$GITHUB_PATH"
else
  export PATH="${bindir}:${PATH}"
fi

"${bindir}/kubeconform" -v || true
