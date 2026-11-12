#!/usr/bin/env bats
# Unit tests for scripts/lib.sh — run with `bats tests/`.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck source=scripts/lib.sh
  source "${ROOT}/scripts/lib.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

@test "kc_split_list normalizes comma, space and newline separators" {
  run kc_split_list "a, b
c  d"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a" ]
  [ "${lines[1]}" = "b" ]
  [ "${lines[2]}" = "c" ]
  [ "${lines[3]}" = "d" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "kc_collect_files finds yaml and yml recursively" {
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/a/b"
  : > "${tmp}/a/one.yaml"
  : > "${tmp}/a/b/two.yml"
  : > "${tmp}/a/readme.md"
  run kc_collect_files "$tmp" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"one.yaml"* ]]
  [[ "$output" == *"two.yml"* ]]
  [[ "$output" != *"readme.md"* ]]
}

@test "kc_collect_files honors ignore substrings" {
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/vendor"
  : > "${tmp}/keep.yaml"
  : > "${tmp}/vendor/skip.yaml"
  run kc_collect_files "$tmp" "vendor/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep.yaml"* ]]
  [[ "$output" != *"skip.yaml"* ]]
}

@test "kc_kubeconform_args defaults to strict json output" {
  run kc_kubeconform_args
  [ "$status" -eq 0 ]
  [[ "$output" == *"-output"* ]]
  [[ "$output" == *"json"* ]]
  [[ "$output" == *"-strict"* ]]
  [[ "$output" == *"master"* ]]
}

@test "kc_kubeconform_args honors explicit version and disables strict" {
  INPUT_KUBERNETES_VERSION="1.30" INPUT_STRICT="false" run kc_kubeconform_args
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.30"* ]]
  [[ "$output" != *"-strict"* ]]
}

@test "kc_kubeconform_args normalizes x.y shorthand to x.y.0" {
  INPUT_KUBERNETES_VERSION="1.30" run kc_kubeconform_args
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.30.0"* ]]
}

@test "kc_kubeconform_args passes 'master' through unchanged" {
  INPUT_KUBERNETES_VERSION="master" run kc_kubeconform_args
  [ "$status" -eq 0 ]
  [[ "$output" == *"master"* ]]
  [[ "$output" != *"master.0"* ]]
}

@test "kc_kubeconform_args adds default schema-location alongside custom ones" {
  INPUT_SCHEMA_LOCATIONS="https://example.com/{{.ResourceKind}}.json" run kc_kubeconform_args
  [ "$status" -eq 0 ]
  # -schema-location must appear at least twice: 'default' + the custom one.
  count="$(printf '%s\n' "$output" | grep -c -- '-schema-location')"
  [ "$count" -eq 2 ]
  [[ "$output" == *"default"* ]]
  [[ "$output" == *"example.com"* ]]
}

@test "kc_annotate returns 0 and emits nothing for all-valid input" {
  run bash -c "source '${ROOT}/scripts/lib.sh'; kc_annotate < '${FIX}/valid.json'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "kc_annotate emits ::error lines and returns 1 on failures" {
  run bash -c "source '${ROOT}/scripts/lib.sh'; kc_annotate < '${FIX}/mixed.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error file=examples/manifests/bad-deployment.yaml"* ]]
  [[ "$output" == *"title=kubeconform%3A Deployment/broken"* ]]
  [[ "$output" == *"could not find schema for Widget"* ]]
  # skipped/valid resources must not be annotated.
  [[ "$output" != *"skipped.yaml"* ]]
  [[ "$output" != *"/deployment.yaml"* ]]
  [[ "$output" != *"service.yaml"* ]]
}

@test "kc_count_failures counts invalid + error only" {
  run bash -c "source '${ROOT}/scripts/lib.sh'; kc_count_failures < '${FIX}/mixed.json'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "kc_summary renders a table and lists failures" {
  run bash -c "source '${ROOT}/scripts/lib.sh'; kc_summary < '${FIX}/mixed.json'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| ✅ Valid | 1 |"* ]]
  [[ "$output" == *"| ❌ Invalid | 1 |"* ]]
  [[ "$output" == *"| ⚠️ Error | 1 |"* ]]
  [[ "$output" == *"| ⏭️ Skipped | 1 |"* ]]
  [[ "$output" == *"**Failures**"* ]]
  [[ "$output" == *"bad-deployment.yaml"* ]]
}

@test "kc_summary celebrates when everything is valid" {
  run bash -c "source '${ROOT}/scripts/lib.sh'; kc_summary < '${FIX}/valid.json'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All manifests valid"* ]]
}

@test "kc_find_line locates a resource by name" {
  tmp="$(mktemp -d)"
  cat > "${tmp}/d.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  replicas: "3"
YAML
  run kc_find_line "${tmp}/d.yaml" "broken"
  [ "$status" -eq 0 ]
  [ "$output" -eq 4 ]
}

@test "kc_find_line falls back to line 1 when name is absent" {
  run kc_find_line "/nonexistent/file.yaml" "whatever"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "kc_merge_json concatenates resources from multiple docs" {
  run bash -c "source '${ROOT}/scripts/lib.sh'; printf '%s\n%s\n' '{\"resources\":[{\"status\":\"statusValid\"}]}' '{\"resources\":[{\"status\":\"statusInvalid\"}]}' | kc_merge_json | jq '.resources | length'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

# kc_check_renderers looks tools up on PATH, so each test runs it with PATH set
# to a temp dir that holds only the stub tools that test wants present, plus
# links to the coreutils the function itself calls.
_renderer_path() {  # _renderer_path TOOL... -> dir with executable stubs
  local dir tool; dir="$(mktemp -d)"
  for tool in tr sed find head; do
    ln -s "$(command -v "$tool")" "${dir}/${tool}"
  done
  for tool in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "${dir}/${tool}"
    chmod +x "${dir}/${tool}"
  done
  printf '%s\n' "$dir"
}

@test "kc_check_renderers fails when kustomize is true and kustomize is missing" {
  bin="$(_renderer_path)"
  PATH="$bin" run kc_check_renderers "true" "" "."
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=kubeconform-ci::kustomize is true"* ]]
}

@test "kc_check_renderers passes when kustomize is true and kustomize is present" {
  bin="$(_renderer_path kustomize)"
  PATH="$bin" run kc_check_renderers "true" "" "."
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "kc_check_renderers only warns in auto mode next to a kustomization file" {
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/overlay"
  : > "${tmp}/overlay/kustomization.yaml"
  bin="$(_renderer_path)"
  PATH="$bin" run kc_check_renderers "auto" "" "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=kubeconform-ci::kustomization file found"* ]]
}

@test "kc_check_renderers is silent in auto mode without kustomization files" {
  tmp="$(mktemp -d)"
  : > "${tmp}/plain.yaml"
  bin="$(_renderer_path)"
  PATH="$bin" run kc_check_renderers "auto" "" "$tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "kc_check_renderers ignores a missing kustomize when kustomize is false" {
  tmp="$(mktemp -d)"
  : > "${tmp}/kustomization.yaml"
  bin="$(_renderer_path)"
  PATH="$bin" run kc_check_renderers "false" "" "$tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "kc_check_renderers fails when helm-charts is set and helm is missing" {
  bin="$(_renderer_path kustomize)"
  PATH="$bin" run kc_check_renderers "auto" "charts/web" "."
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=kubeconform-ci::helm-charts is set"* ]]
}

@test "kc_check_renderers passes when helm-charts is set and helm is present" {
  bin="$(_renderer_path helm)"
  PATH="$bin" run kc_check_renderers "false" "charts/web" "."
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Render failures: scripts/kubeconform-ci.sh runs with stub kustomize, helm and
# kubeconform first on PATH. The kubeconform stub logs what it was asked to
# validate, so the tests can check that partial render output never reaches it.
# Each test keeps all temp files under one mktemp dir that teardown removes.
teardown() {
  if [ -n "${KC_TMP:-}" ]; then
    rm -rf "$KC_TMP"
    unset KC_TMP
  fi
}

_render_stubs() {  # creates $KC_TMP with bin/ stubs; RENDER_RC is the render exit code
  KC_TMP="$(mktemp -d)"
  mkdir -p "${KC_TMP}/bin"
  local tool
  for tool in kustomize helm; do
    cat > "${KC_TMP}/bin/${tool}" <<STUB
#!/bin/sh
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: partial-${tool}\n'
echo "Error: ${tool} stub exploded" >&2
exit ${RENDER_RC:-1}
STUB
  done
  cat > "${KC_TMP}/bin/kubeconform" <<STUB
#!/bin/sh
echo "args: \$*" >> "${KC_TMP}/kubeconform.log"
for a in "\$@"; do
  [ "\$a" = "-" ] && cat >> "${KC_TMP}/kubeconform.log"
done
printf '{"resources":[]}\n'
STUB
  chmod +x "${KC_TMP}/bin/"*
  : > "${KC_TMP}/kubeconform.log"
  : > "${KC_TMP}/output"
}

@test "kubeconform-ci fails and annotates when kustomize build fails" {
  _render_stubs
  mkdir -p "${KC_TMP}/overlay"
  : > "${KC_TMP}/overlay/kustomization.yaml"
  PATH="${KC_TMP}/bin:${PATH}" GITHUB_OUTPUT="${KC_TMP}/output" INPUT_DIRS="${KC_TMP}/overlay" \
    run bash "${ROOT}/scripts/kubeconform-ci.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error file=${KC_TMP}/overlay/kustomization.yaml"* ]]
  [[ "$output" == *"kustomize build ${KC_TMP}/overlay failed (exit 1)"* ]]
  [[ "$output" == *"Error: kustomize stub exploded"* ]]
  [[ "$output" != *"all manifests valid"* ]]
  grep -q 'invalid-count=1' "${KC_TMP}/output"
  # The partial output of the failed build must not be validated.
  run grep -q 'partial-kustomize' "${KC_TMP}/kubeconform.log"
  [ "$status" -ne 0 ]
}

@test "kubeconform-ci fails and annotates when helm template fails" {
  _render_stubs
  mkdir -p "${KC_TMP}/manifests" "${KC_TMP}/chart"
  : > "${KC_TMP}/manifests/plain.yaml"
  PATH="${KC_TMP}/bin:${PATH}" GITHUB_OUTPUT="${KC_TMP}/output" \
    INPUT_DIRS="${KC_TMP}/manifests" INPUT_HELM_CHARTS="${KC_TMP}/chart" \
    run bash "${ROOT}/scripts/kubeconform-ci.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error file=${KC_TMP}/chart/Chart.yaml"* ]]
  [[ "$output" == *"helm template chart ${KC_TMP}/chart failed (exit 1)"* ]]
  [[ "$output" == *"Error: helm stub exploded"* ]]
  grep -q 'invalid-count=1' "${KC_TMP}/output"
  # Plain manifests are still validated; the partial chart output is not.
  grep -q 'plain.yaml' "${KC_TMP}/kubeconform.log"
  run grep -q 'partial-helm' "${KC_TMP}/kubeconform.log"
  [ "$status" -ne 0 ]
}

@test "kubeconform-ci validates rendered output when the render succeeds" {
  RENDER_RC=0 _render_stubs
  mkdir -p "${KC_TMP}/overlay" "${KC_TMP}/chart"
  : > "${KC_TMP}/overlay/kustomization.yaml"
  PATH="${KC_TMP}/bin:${PATH}" GITHUB_OUTPUT="${KC_TMP}/output" \
    INPUT_DIRS="${KC_TMP}/overlay" INPUT_HELM_CHARTS="${KC_TMP}/chart" \
    run bash "${ROOT}/scripts/kubeconform-ci.sh"
  [ "$status" -eq 0 ]
  grep -q 'invalid-count=0' "${KC_TMP}/output"
  grep -q 'partial-kustomize' "${KC_TMP}/kubeconform.log"
  grep -q 'partial-helm' "${KC_TMP}/kubeconform.log"
}
