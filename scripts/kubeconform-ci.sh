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

# render_target LABEL KIND NAME CMD... -> one kubeconform JSON doc.
# Runs the render command into a temp file. On success the rendered YAML is
# validated under LABEL. On a non-zero exit the output is dropped, even if
# partial, and a statusError entry carrying the command's stderr is returned
# instead, so the failure is annotated, counted and fails the step.
render_target() {
  local label="$1" kind="$2" name="$3"; shift 3
  local out err rc msg
  out="$(mktemp)"; err="$(mktemp)"
  set +e
  "$@" >"$out" 2>"$err"
  rc=$?
  set -e
  # Keep the tool's stderr in the step log (warnings included).
  cat "$err" >&2
  if [ "$rc" -eq 0 ]; then
    run_stream "$label" < "$out"
  else
    echo "kubeconform-ci: '$*' failed (exit ${rc})" >&2
    msg="$(head -c 2000 "$err")"
    [ -z "$msg" ] && msg="no stderr output"
    jq -n --arg f "$label" --arg k "$kind" --arg n "$name" \
      --arg m "${*} failed (exit ${rc}): ${msg}" \
      '{resources:[{filename:$f,kind:$k,name:$n,status:"statusError",msg:$m}]}'
  fi
  rm -f "$out" "$err"
}

main() {
  # Requested rendering with a missing tool must fail, not validate raw partials.
  kc_check_renderers "${INPUT_KUSTOMIZE:-auto}" "${INPUT_HELM_CHARTS:-}" "${INPUT_DIRS:-.}" || return 1

  mapfile -t KARGS < <(kc_kubeconform_args)

  local -a kdirs=()
  mapfile -t kdirs < <(kustomize_dirs)

  # Plain files: everything collected, minus anything inside a Kustomize dir.
  # kustomization.yaml itself is Kustomize config, not a validatable manifest,
  # so it is always excluded (it is rendered separately when kustomize exists).
  local files ignore="${INPUT_IGNORE_PATHS:-}"
  ignore+=$'\n'"kustomization.yaml"$'\n'"kustomization.yml"
  local kd kfile
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
    kfile="${kd}/kustomization.yaml"
    [ ! -f "$kfile" ] && [ -f "${kd}/kustomization.yml" ] && kfile="${kd}/kustomization.yml"
    render_target "$kfile" "Kustomization" "$kd" kustomize build "$kd" >> "$docs"
    n_targets=$((n_targets + 1))
  done

  local chart
  while IFS= read -r chart || [ -n "$chart" ]; do
    [ -z "$chart" ] && continue
    echo "kubeconform-ci: rendering helm chart ${chart}"
    render_target "${chart%/}/Chart.yaml" "HelmChart" "$chart" \
      helm template "$(basename "$chart")" "$chart" >> "$docs"
    n_targets=$((n_targets + 1))
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
