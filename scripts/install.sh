#!/usr/bin/env bash
# install.sh — fetch the kubeconform binary and put it on PATH for later steps.
# Runs inside the composite action.
#
# - kubeconform: the requested KUBECONFORM_VERSION is always installed into
#   ${HOME}/.kubeconform-ci/bin, which is prepended to PATH, so it wins over any
#   kubeconform already on the runner. The download is skipped only when that
#   directory already holds the requested version.
# - yq: fetched only when it is not already on PATH.
# - helm and kustomize are NOT installed. Helm charts and Kustomize overlays are
#   rendered only when those tools are already on the runner's PATH.
#
# Every download is verified against the sha256 checksum file published with
# the upstream release; a mismatch aborts the step.
set -euo pipefail

ver="${KUBECONFORM_VERSION:-0.8.0}"
ver="${ver#v}"
yq_ver="4.54.1"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
esac

bindir="${HOME}/.kubeconform-ci/bin"
mkdir -p "$bindir"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha256_of() {  # sha256_of FILE -> hex digest on stdout
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_sha256() {  # verify_sha256 FILE EXPECTED NAME
  local actual
  if [ -z "$2" ]; then
    echo "kubeconform-ci: no checksum published for $3" >&2
    return 1
  fi
  actual="$(sha256_of "$1")"
  if [ "$actual" != "$2" ]; then
    echo "kubeconform-ci: checksum mismatch for $3 (expected $2, got ${actual})" >&2
    return 1
  fi
  echo "kubeconform-ci: sha256 OK for $3"
}

# kubeconform -------------------------------------------------------------
have=""
if [ -x "${bindir}/kubeconform" ]; then
  have="$("${bindir}/kubeconform" -v 2>/dev/null || true)"
fi
if [ "${have#v}" != "$ver" ]; then
  base="https://github.com/yannh/kubeconform/releases/download/v${ver}"
  asset="kubeconform-${os}-${arch}.tar.gz"
  echo "kubeconform-ci: installing kubeconform v${ver} (${os}/${arch})"
  curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}"
  curl -fsSL "${base}/CHECKSUMS" -o "${tmp}/kubeconform.sums"
  # CHECKSUMS lines: "<sha256>  <asset>"
  want="$(awk -v f="$asset" '$2 == f {print $1}' "${tmp}/kubeconform.sums")"
  verify_sha256 "${tmp}/${asset}" "$want" "$asset"
  tar -xzf "${tmp}/${asset}" -C "$tmp" kubeconform
  install -m0755 "${tmp}/kubeconform" "${bindir}/kubeconform"
fi

# yq (optional) -----------------------------------------------------------
if ! command -v yq >/dev/null 2>&1 && [ ! -x "${bindir}/yq" ]; then
  base="https://github.com/mikefarah/yq/releases/download/v${yq_ver}"
  asset="yq_${os}_${arch}"
  echo "kubeconform-ci: installing yq v${yq_ver}"
  if curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}" \
    && curl -fsSL "${base}/checksums-bsd" -o "${tmp}/yq.sums"; then
    # checksums-bsd lines: "SHA256 (<asset>) = <sha256>"
    want="$(awk -v f="(${asset})" '$1 == "SHA256" && $2 == f {print $4}' "${tmp}/yq.sums")"
    verify_sha256 "${tmp}/${asset}" "$want" "$asset"
    install -m0755 "${tmp}/${asset}" "${bindir}/yq"
  else
    echo "kubeconform-ci: yq download failed, skipping (yq is optional)"
  fi
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bindir" >> "$GITHUB_PATH"
else
  export PATH="${bindir}:${PATH}"
fi

"${bindir}/kubeconform" -v || true
