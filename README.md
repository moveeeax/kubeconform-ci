# kubeconform-ci

[![ci](https://github.com/moveeeax/kubeconform-ci/actions/workflows/ci.yml/badge.svg)](https://github.com/moveeeax/kubeconform-ci/actions/workflows/ci.yml)
![language](https://img.shields.io/badge/action-composite-blue)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Validate every Kubernetes manifest against the right schema on every PR.

A drop-in composite GitHub Action that wraps [`kubeconform`](https://github.com/yannh/kubeconform).
It finds your manifests, renders Kustomize overlays and Helm charts, validates everything
(CRDs included) against a pinned Kubernetes version, and turns each failure into an inline
PR annotation plus a job-summary table.

## Why

`kubectl apply --dry-run=server` needs a cluster; `kubeval` is unmaintained and can't see CRDs.
`kubeconform` is fast and offline, but on its own it doesn't render Kustomize/Helm, doesn't
surface `file:line` annotations, and needs its version and CRD schema flags wired up. This action
is that wiring, so a PR check is a single `uses:` block.

## Usage

```yaml
- uses: moveeeax/kubeconform-ci@v0
  with:
    kubernetes-version: "1.30"
    dirs: manifests/
```

A failing manifest annotates the PR at the offending file and blocks the check:

```
::error file=manifests/deploy.yaml,line=6,title=kubeconform: Deployment/web::
  '/spec/replicas' expected integer or null, but got string
```

See [`examples/workflow.yml`](examples/workflow.yml) for a complete pull-request workflow.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `dirs` | `.` | Directories or files to validate (space / newline / comma separated). |
| `kubernetes-version` | `master` | Target version, e.g. `1.30`. `x.y` is expanded to `x.y.0`; `master`/`auto` use the latest schemas. |
| `ignore-paths` | `` | Path substrings to skip. |
| `schema-locations` | `` | Extra schema locations for CRDs (one per line). Adding any keeps the built-in `default` too. |
| `strict` | `true` | Disallow unknown / duplicate fields. |
| `summary` | `true` | Write a Markdown results table to the job summary. |
| `kustomize` | `auto` | Render dirs containing `kustomization.yaml` before validating (`auto`/`true`/`false`). |
| `helm-charts` | `` | Chart directories to render with `helm template` (one per line). |
| `kubeconform-version` | `0.8.0` | kubeconform release to install. Always installed and put first on `PATH`, even if another `kubeconform` is already present. |
| `extra-args` | `` | Extra raw arguments forwarded to kubeconform. |

## Outputs

| Output | Description |
| --- | --- |
| `invalid-count` | Number of manifests that failed validation. |

## How it works

1. `scripts/install.sh` fetches the requested `kubeconform` release (and `yq` when missing),
   verifies each download against the sha256 checksum file published with the upstream release,
   and puts them first on `PATH`.
2. `scripts/kubeconform-ci.sh` collects `*.yaml`/`*.yml` under `dirs`, honoring `ignore-paths`.
3. Any directory with a `kustomization.yaml` is rendered with `kustomize build`; charts listed in
   `helm-charts` are rendered with `helm template`. Rendered output is validated instead of the
   raw partials, so overlays are checked as they actually deploy. The action does not install
   `kustomize` or `helm`: they must already be on the runner's `PATH`, otherwise that rendering
   step is skipped.
4. `kubeconform -output json` results from every source are merged, converted to GitHub
   `::error` annotations (`file:line` located by resource name), and summarized. Any invalid or
   errored resource fails the step.

### Custom resources

Point `schema-locations` at a CRD schema catalog — the built-in `default` location is kept
automatically so core types still resolve:

```yaml
with:
  schema-locations: |
    https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
```

## Development

```bash
bats tests/                 # unit tests for the shell library (needs bats + jq)
shellcheck scripts/*.sh
bash tests/integration.sh   # end-to-end against examples/ (needs kubeconform, kustomize)
```

## License

MIT — see [LICENSE](LICENSE).
