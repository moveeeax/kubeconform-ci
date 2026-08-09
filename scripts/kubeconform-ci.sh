#!/usr/bin/env bash
# kubeconform-ci.sh — orchestrator invoked by the composite action.
# Collects manifests, optionally renders Kustomize dirs and Helm charts, runs
# kubeconform, emits PR annotations + a job summary, and fails on invalid input.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${HERE}/lib.sh"

# Directories (under INPUT_DIRS) that Kustomize will render, so their raw
# partial files are not double-validated as standalone manifests.
kustomize_dirs() {
  local mode="${INPUT_KUSTOMIZE:-auto}" d
  [ "$mode" = "false" ] && return 0
  command -v kustomize >/dev/null 2>&1 || return 0
  while IFS= read -r d || [ -n "$d" ]; do
    [ -z "$d" ] && continue
    [ -d "$d" ] || continue
    if [ -f "${d}/kustomization.yaml" ] || [ -f "${d}/kustomization.yml" ]; then
      printf '%s\n' "${d%/}"
    fi
    find "$d" -type f \( -name kustomization.yaml -o -name kustomization.yml \) 2>/dev/null \
      | while IFS= read -r k; do dirname "$k"; done
  done < <(kc_split_list "${INPUT_DIRS:-.}") | LC_ALL=C sort -u
}

# _kc_json_or_error RC ERRFILE OUT  -> a JSON doc with a resources array.
# A non-zero exit on invalid manifests is fine (the JSON is still valid), but a
# tool failure that produces no JSON must surface as an error, never a silent pass.
_kc_json_or_error() {
  local rc="$1" errfile="$2" doc="$3" msg
  if printf '%s' "$doc" | jq -e 'has("resources")' >/dev/null 2>&1; then
    printf '%s\n' "$doc"
    return 0
  fi
  msg="$(tr '\n' ' ' < "$errfile" 2>/dev/null | head -c 300)"
  [ -z "$msg" ] && msg="kubeconform failed (exit ${rc})"
  jq -n --arg m "$msg" \
    '{resources:[{filename:"kubeconform",kind:"kubeconform",name:"invocation",status:"statusError",msg:$m}]}'
}

run_kubeconform() {  # positional file args; prints one kubeconform JSON doc
  local doc rc err; err="$(mktemp)"
  set +e
  doc="$(kubeconform "${KARGS[@]}" "$@" 2>"$err")"
  rc=$?
  set -e
  _kc_json_or_error "$rc" "$err" "$doc"
  rm -f "$err"
}

run_stream() {  # $1=label; stdin=rendered YAML; prints JSON with filename=label
  local label="$1" doc rc err; err="$(mktemp)"
  set +e
  doc="$(kubeconform "${KARGS[@]}" - 2>"$err")"
  rc=$?
  set -e
  _kc_json_or_error "$rc" "$err" "$doc" \
    | jq --arg f "$label" '.resources |= (map(.filename = (.filename | if . == "stdin" or . == "" or . == null then $f else . end)))'
  rm -f "$err"
}

main() {
  mapfile -t KARGS < <(kc_kubeconform_args)

  local -a kdirs=()
  mapfile -t kdirs < <(kustomize_dirs)

  # Plain files: everything collected, minus anything inside a Kustomize dir.
  # kustomization.yaml itself is Kustomize config, not a validatable manifest,
  # so it is always excluded (it is rendered separately when kustomize exists).
  local files ignore="${INPUT_IGNORE_PATHS:-}"
  ignore+=$'\n'"kustomization.yaml"$'\n'"kustomization.yml"
  local kd
  for kd in "${kdirs[@]}"; do
    [ -n "$kd" ] && ignore+=$'\n'"${kd}/"
  done
  files="$(kc_collect_files "${INPUT_DIRS:-.}" "$ignore")"

  local docs; docs="$(mktemp)"
  local n_targets=0

  if [ -n "$files" ]; then
    local -a farr=(); mapfile -t farr <<< "$files"
    n_targets=$((n_targets + ${#farr[@]}))
    run_kubeconform "${farr[@]}" >> "$docs"
  fi

  for kd in "${kdirs[@]}"; do
    [ -z "$kd" ] && continue
    echo "kubeconform-ci: rendering kustomize ${kd}"
    if kustomize build "$kd" 2>/dev/null | run_stream "${kd}/kustomization.yaml" >> "$docs"; then
      n_targets=$((n_targets + 1))
    fi
  done

  local chart
  while IFS= read -r chart || [ -n "$chart" ]; do
    [ -z "$chart" ] && continue
    command -v helm >/dev/null 2>&1 || { echo "kubeconform-ci: helm not installed, skipping ${chart}"; continue; }
    echo "kubeconform-ci: rendering helm chart ${chart}"
    if helm template "$(basename "$chart")" "$chart" 2>/dev/null | run_stream "${chart}/Chart.yaml" >> "$docs"; then
      n_targets=$((n_targets + 1))
    fi
  done < <(kc_split_list "${INPUT_HELM_CHARTS:-}")

  if [ "$n_targets" -eq 0 ]; then
    echo "kubeconform-ci: no manifests found under '${INPUT_DIRS:-.}'"
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "invalid-count=0" >> "$GITHUB_OUTPUT"
    rm -f "$docs"
    return 0
  fi

  local merged; merged="$(kc_merge_json < "$docs")"
  rm -f "$docs"

  printf '%s' "$merged" | kc_annotate || true

  if [ "${INPUT_SUMMARY:-true}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s' "$merged" | kc_summary >> "$GITHUB_STEP_SUMMARY"
  fi

  local bad; bad="$(printf '%s' "$merged" | kc_count_failures)"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "invalid-count=${bad}" >> "$GITHUB_OUTPUT"

  if [ "${bad:-0}" -gt 0 ]; then
    echo "kubeconform-ci: ${bad} manifest(s) failed validation"
    return 1
  fi
  echo "kubeconform-ci: all manifests valid ✅"
  return 0
}

main "$@"
