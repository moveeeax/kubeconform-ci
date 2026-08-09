#!/usr/bin/env bash
# lib.sh — pure helpers for kubeconform-ci.
# Sourced by scripts/kubeconform-ci.sh and by tests/lib.bats. Sourcing has no
# side effects; every function is deterministic given its inputs so it can be
# unit-tested without kubeconform, helm or kustomize installed.

# kc_split_list LIST -> one item per line.
# Accepts comma / newline / space separated input; drops empties.
kc_split_list() {
  printf '%s' "${1:-}" | tr ',\n' '  ' | tr -s ' ' '\n' | sed '/^[[:space:]]*$/d'
}

# _kc_filter_ignore IGNORE_LINES  (reads file paths on stdin)
# Drops any path that contains one of the ignore substrings.
_kc_filter_ignore() {
  local ignore_lines="$1" f pat skip
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    skip=0
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      case "$f" in
        *"$pat"*) skip=1; break ;;
      esac
    done <<< "$ignore_lines"
    if [ "$skip" -eq 0 ]; then printf '%s\n' "$f"; fi
  done
  return 0
}

# kc_collect_files DIRS IGNORE -> newline list of *.yaml/*.yml under DIRS,
# excluding paths matching an IGNORE substring. DIRS entries may be dirs or files.
kc_collect_files() {
  local dirs="$1" ignore="${2:-}"
  local ignore_lines d
  ignore_lines="$(kc_split_list "$ignore")"
  {
    while IFS= read -r d || [ -n "$d" ]; do
      [ -z "$d" ] && continue
      if [ -d "$d" ]; then
        find "$d" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null
      elif [ -f "$d" ]; then
        printf '%s\n' "$d"
      fi
    done < <(kc_split_list "$dirs")
  } | LC_ALL=C sort -u | _kc_filter_ignore "$ignore_lines"
}

# kc_kubeconform_args -> kubeconform CLI args, one per line, from INPUT_* env.
# Reads INPUT_STRICT, INPUT_KUBERNETES_VERSION, INPUT_SCHEMA_LOCATIONS, INPUT_EXTRA_ARGS.
kc_kubeconform_args() {
  local out=("-output" "json")
  if [ "${INPUT_STRICT:-true}" = "true" ]; then
    out+=("-strict")
  fi
  local ver="${INPUT_KUBERNETES_VERSION:-master}"
  ver="${ver#v}"
  if [ -n "$ver" ] && [ "$ver" != "auto" ]; then
    # kubeconform wants a full x.y.z; accept the common 'x.y' shorthand.
    if printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+$'; then
      ver="${ver}.0"
    fi
    out+=("-kubernetes-version" "$ver")
  fi
  local locs loc
  locs="$(kc_split_list "${INPUT_SCHEMA_LOCATIONS:-}")"
  if [ -n "$locs" ]; then
    # Custom schema locations replace the built-in default, so add it back
    # explicitly to keep resolving core Kubernetes types alongside CRDs.
    out+=("-schema-location" "default")
    while IFS= read -r loc; do
      [ -n "$loc" ] && out+=("-schema-location" "$loc")
    done <<< "$locs"
  fi
  if [ -n "${INPUT_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    local extra=(${INPUT_EXTRA_ARGS})
    out+=("${extra[@]}")
  fi
  printf '%s\n' "${out[@]}"
}

_kc_esc_data() {
  local s="${1:-}"
  s="${s//%/%25}"; s="${s//$'\r'/%0D}"; s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

_kc_esc_prop() {
  local s
  s="$(_kc_esc_data "${1:-}")"
  s="${s//,/%2C}"; s="${s//:/%3A}"
  printf '%s' "$s"
}

# kc_find_line FILE NAME -> best-effort 1-based line of the resource, default 1.
kc_find_line() {
  local file="$1" name="${2:-}" n
  if [ -n "$name" ] && [ -f "$file" ]; then
    n="$(grep -nE "name:[[:space:]]+[\"']?${name}([\"']|[[:space:]]|\$)" "$file" 2>/dev/null | head -n1 | cut -d: -f1)"
    if [ -n "$n" ]; then printf '%s\n' "$n"; return 0; fi
  fi
  printf '1\n'
}

# kc_annotate  (reads kubeconform JSON on stdin)
# Emits a GitHub ::error workflow command per invalid/errored resource.
# Returns 1 when at least one failure is present, else 0.
kc_annotate() {
  local json rows file kind name msg line title
  json="$(cat)"
  rows="$(printf '%s' "$json" | jq -r '
    (.resources // [])[]
    | select(.status == "statusInvalid" or .status == "statusError")
    | [ (.filename // "manifest"), (.kind // ""), (.name // ""),
        ((.msg // "") | gsub("[\r\n]+"; " ")) ]
    | @tsv' 2>/dev/null)"
  [ -z "$rows" ] && return 0
  while IFS=$'\t' read -r file kind name msg; do
    [ -z "$file" ] && file="manifest"
    line="$(kc_find_line "$file" "$name")"
    title="kubeconform: ${kind:-Resource}/${name:-?}"
    printf '::error file=%s,line=%s,title=%s::%s\n' \
      "$(_kc_esc_prop "$file")" "$line" "$(_kc_esc_prop "$title")" "$(_kc_esc_data "$msg")"
  done <<< "$rows"
  return 1
}

# kc_summary  (reads kubeconform JSON on stdin) -> Markdown summary on stdout.
kc_summary() {
  jq -r '
    (.resources // []) as $r
    | ($r | map(select(.status=="statusValid"))   | length) as $valid
    | ($r | map(select(.status=="statusInvalid")) | length) as $invalid
    | ($r | map(select(.status=="statusError"))   | length) as $error
    | ($r | map(select(.status=="statusSkipped")) | length) as $skipped
    | ( "### kubeconform-ci",
        "",
        "| Result | Count |",
        "| --- | ---: |",
        "| ✅ Valid | \($valid) |",
        "| ❌ Invalid | \($invalid) |",
        "| ⚠️ Error | \($error) |",
        "| ⏭️ Skipped | \($skipped) |",
        "" )
    , ( if ($invalid + $error) > 0
        then ( "**Failures**", "",
               ( $r[]
                 | select(.status=="statusInvalid" or .status=="statusError")
                 | "- `\(.filename // "manifest")` — \(.kind // "Resource")/\(.name // "?"): \((.msg // "") | gsub("[\r\n]+"; " "))" ) )
        else ( "All manifests valid. 🎉" ) end )
  '
}

# kc_count_failures  (reads kubeconform JSON on stdin) -> integer failure count.
kc_count_failures() {
  jq '[ (.resources // [])[] | select(.status=="statusInvalid" or .status=="statusError") ] | length' 2>/dev/null || echo 0
}

# kc_merge_json  (reads a stream of kubeconform JSON docs on stdin)
# -> a single {"resources":[...]} doc combining every input doc's resources.
kc_merge_json() {
  jq -s '{ resources: ( map(.resources // []) | add // [] ) }'
}
