# kargo-helm-prom-stack

A GitOps repository for deploying and continuously promoting [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) across three environments using [Kargo](https://kargo.akuity.io) for continuous promotion and [Argo CD](https://argo-cd.readthedocs.io) for continuous reconciliation.

## Table of Contents

- [Overview](#overview)
- [Tech Stack](#tech-stack)
- [Repository Structure](#repository-structure)
- [Branch Strategy](#branch-strategy)
- [How It Works](#how-it-works)
  - [Bootstrap](#bootstrap)
  - [ArgoCD Applications](#argocd-applications)
  - [Kargo Pipeline](#kargo-pipeline)
  - [Promotion Flow](#promotion-flow)
  - [Verification](#verification)
- [Addons](#addons)
- [AppSet Generation](#appset-generation)
- [RBAC](#rbac)
- [Environments](#environments)
- [Forking This Repo](#forking-this-repo)

---

## Overview

This repo manages a single addon (`kube-prometheus-stack`) across three environments: `dev`, `test`, and `prod`. It uses a two-branch GitOps pattern:

- **`main`** — source of truth for configuration, Kargo resources, ArgoCD app definitions, and Helm values
- **`addon/kube-prometheus.stack/stage/<stage>`** — rendered output branches, one per environment; ArgoCD syncs from these

When Kargo promotes a new chart version or image tag, it updates the `main` branch with the new versions and writes rendered Kustomize manifests to the corresponding stage branch. ArgoCD picks up the stage branch changes and reconciles the cluster.

---

## Tech Stack

| Tool | Role |
|------|------|
| [Argo CD](https://argo-cd.readthedocs.io) | Continuous reconciliation — syncs rendered manifests from stage branches to clusters |
| [Kargo](https://kargo.akuity.io) | Continuous promotion — promotes chart versions and image tags across stages |
| [Kustomize](https://kustomize.io) | Renders Helm charts via `helmCharts` and bundles extras (ServiceMonitors, dashboards) |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) | The Helm chart being deployed (Prometheus, Grafana, Alertmanager) |

---

## Repository Structure

```
kargo-helm-prom-stack/
├── .github/workflows/
│   └── generate-apps.yaml          # CI: regenerates argocd/ from appsets/ on push
│
├── addons/                         # Addon source — one subdirectory per addon
│   └── kube-prometheus-stack/
│       ├── stage/                  # Per-environment Helm + Kustomize config (main branch)
│       │   ├── .gitignore          # Ignores charts/ and Chart.lock
│       │   ├── dev/
│       │   │   ├── kustomization.yaml   # Helm chart version + extras reference
│       │   │   └── values.yaml          # Environment-specific Helm values
│       │   ├── test/
│       │   │   ├── kustomization.yaml
│       │   │   └── values.yaml
│       │   └── prod/
│       │       ├── kustomization.yaml
│       │       └── values.yaml
│       └── extras/                 # Additional resources bundled with the chart
│           ├── kustomization.yaml  # Builds ServiceMonitors + Grafana dashboard ConfigMap
│           ├── service-monitors.yaml
│           └── akuity-dashboard.json
│
├── appsets/                        # ArgoCD ApplicationSet definitions (one per addon)
│   └── kube-prometheus-stack.yaml
│
├── argocd/                         # ArgoCD resources synced by the bootstrap app
│   ├── appproj.yaml                # kargo-addons AppProject
│   ├── kargo-resources-app.yaml    # App that syncs kargo-resources/ to the Kargo cluster
│   └── kube-prometheus-stack.yaml  # Generated Applications (do not edit manually)
│
├── kargo-resources/                # Kargo resource definitions (one subdirectory per addon)
│   └── kube-prometheus-stack/
│       ├── project.yaml            # Kargo Project + auto-promotion policies
│       ├── warehouse.yaml          # Warehouses: chart version, non-operator images, extras
│       ├── stages.yaml             # dev → test → prod stage definitions
│       ├── promotiontask.yaml      # Reusable promotion steps
│       ├── promoteRole.yaml        # RBAC for non-prod promotions
│       └── analysisTemplates.yaml  # Post-promotion verification queries
│
├── generate-apps.sh                # Script: generates argocd/ from appsets/
└── kargo-addons-bootstrap.yaml     # Bootstrap Application — apply this once to get started
```

---

## Branch Strategy

This repo uses **per-addon stage branches** to separate rendered output from source config:

| Branch | Purpose |
|--------|---------|
| `main` | All source config: values, kustomizations, Kargo resources, ArgoCD definitions |
| `addon/kube-prometheus.stack/stage/dev` | Rendered manifests for dev — ArgoCD syncs this |
| `addon/kube-prometheus.stack/stage/test` | Rendered manifests for test — ArgoCD syncs this |
| `addon/kube-prometheus.stack/stage/prod` | Rendered manifests for prod — ArgoCD syncs this |

Stage branches contain only the Kustomize-rendered output (`manifest.yaml`). They are written exclusively by Kargo promotions and should never be edited manually.

The naming convention `addon/<addon-name>/stage/<stage>` namespaces branches by addon, preventing collisions as more addons are added.

---

## How It Works

### Bootstrap

To bootstrap the entire stack from scratch, apply `kargo-addons-bootstrap.yaml` once to your in-cluster ArgoCD:

```bash
kubectl apply -f kargo-addons-bootstrap.yaml
```

This creates an Argo CD `Application` that recursively syncs the `argocd/` directory, which in turn creates:

- The `kargo-addons` AppProject
- The `kargo-resources` Application (syncs Kargo resources to the Kargo cluster)
- The generated `kube-prometheus-stack-{dev,test,prod}` Applications

### ArgoCD Applications

ArgoCD applications are defined in `argocd/` and managed in two ways:

**Generated applications** (`argocd/kube-prometheus-stack.yaml`) are produced by running `./generate-apps.sh` against the ApplicationSet in `appsets/kube-prometheus-stack.yaml`. These represent the per-environment `kube-prometheus-stack-{dev,test,prod}` Applications. They are auto-generated — do not edit this file directly.

**Manually maintained** files (`argocd/appproj.yaml`, `argocd/kargo-resources-app.yaml`) are edited directly in `main`.

Each generated Application:
- Targets a specific cluster by environment name (`dev`, `test`, `prod`)
- Deploys to the `monitoring` namespace
- Syncs from the addon's stage branch (`addon/kube-prometheus.stack/stage/<stage>`)
- Uses `ServerSideApply` and `automated` sync with pruning

### Kargo Pipeline

Kargo watches for new chart versions, image tags, and extras changes, then promotes them through stages automatically (dev/test) or with a manual gate (prod).

#### Warehouses

Three warehouses poll for new versions every 5 minutes:

| Warehouse | Tracks |
|-----------|--------|
| `kube-prometheus-stack` | Helm chart from `https://prometheus-community.github.io/helm-charts` |
| `non-operator-images` | Container images: Prometheus, Grafana, Alertmanager |
| `addon-extras` | Git commits to `addons/kube-prometheus-stack/extras/` on `main` |

Image selection uses `SemVer` strategy with `strictSemvers: true` to avoid pre-release tags. Tag regexes are applied per image:
- Prometheus: `^v[0-9]+\.[0-9]+\.[0-9]+$`
- Grafana: `^[0-9]+\.[0-9]+\.[0-9]+$`
- Alertmanager: `^v[0-9]+\.[0-9]+\.[0-9]+$`

The `addon-extras` warehouse uses an `expressionFilter` to ignore commits authored by Kargo, preventing a promotion loop where Kargo's own commits to `main` would trigger new freight.

#### Stages

Three stages form a linear promotion pipeline:

```
Warehouse ──► dev (auto) ──► test (auto) ──► prod (manual gate)
```

| Stage | Auto-promote | Shard | Color |
|-------|-------------|-------|-------|
| `dev` | Yes | dev | red |
| `test` | Yes | test | orange |
| `prod` | No | prod | green |

`dev` pulls freight directly from the warehouses. `test` pulls from `dev`. `prod` pulls from `test`.

### Promotion Flow

When Kargo promotes a stage, the `default-promote` PromotionTask runs these steps:

1. **`git-clone`** — checks out `main` to `./src` and the target stage branch to `./out` (creating it if it doesn't exist)
2. **`git-clear`** — wipes `./out` so stale files from prior promotions don't persist
3. **`yaml-update` (chart version)** — updates `helmCharts[0].version` in `./src/addons/kube-prometheus-stack/stage/<stage>/kustomization.yaml`
4. **`yaml-update` (images)** — updates image tags in `./src/addons/kube-prometheus-stack/stage/<stage>/values.yaml` for Grafana, Alertmanager, and Prometheus
5. **`kustomize-build`** — renders the full manifest (chart + extras) into `./out/manifest.yaml`
6. **`git-commit` + `git-push` (src)** — commits updated versions to `main`
7. **`git-commit` + `git-push` (out)** — commits rendered manifests to the stage branch
8. **`argocd-update`** — forces an immediate Argo CD sync rather than waiting for the next polling interval

The result is two commits per promotion: one to `main` with updated versions, one to the stage branch with fresh rendered manifests.

### Verification

After each promotion, Kargo runs the `prometheus-is-up` AnalysisTemplate. It queries the in-cluster Prometheus to confirm no `kube-prometheus-stack` pods are in a non-Running state:

```promql
sum(kube_pod_status_phase{namespace='monitoring',phase!='Running',pod=~".*kube-prometheus-stack.*"}) by (pod)
```

The analysis runs 6 checks at 10-second intervals, with a failure limit of 1. If verification fails, the promotion is marked as failed and does not proceed to the next stage.

---

## Addons

Each addon follows this convention:

```
addons/<addon-name>/
  stage/
    dev/   kustomization.yaml + values.yaml
    test/  kustomization.yaml + values.yaml
    prod/  kustomization.yaml + values.yaml
  extras/
    kustomization.yaml  (ServiceMonitors, ConfigMaps, etc.)
    ...

kargo-resources/<addon-name>/
  project.yaml
  warehouse.yaml
  stages.yaml
  promotiontask.yaml
  promoteRole.yaml
  analysisTemplates.yaml

appsets/<addon-name>.yaml   →   argocd/<addon-name>.yaml (generated)
```

Each `stage/<stage>/kustomization.yaml` uses Kustomize's `helmCharts` field to render the chart, and includes `../../extras` as a resource to bundle any additional manifests.

To add a new addon:
1. Create `addons/<addon-name>/stage/{dev,test,prod}/kustomization.yaml` and `values.yaml`
2. Create `addons/<addon-name>/extras/` with any additional resources
3. Create `appsets/<addon-name>.yaml` — Kargo-authorized ApplicationSet
4. Run `./generate-apps.sh` (or let the GitHub Action do it) to produce `argocd/<addon-name>.yaml`
5. Create `kargo-resources/<addon-name>/` with project, warehouse, stages, promotiontask, and analysis template

---

## AppSet Generation

ArgoCD ApplicationSets in `appsets/` are the source of truth for generating Applications in `argocd/`. The generated files are committed to `main` and synced by the bootstrap app.

**To regenerate manually:**

```bash
export ARGOCD_SERVER=<your-argocd-server>
export TOKEN=<your-argocd-token>
./generate-apps.sh
```

**Automated via GitHub Actions:**

The `.github/workflows/generate-apps.yaml` workflow triggers on any push to `main` that changes `appsets/*.yaml`. It installs the ArgoCD CLI, runs `generate-apps.sh`, and opens a pull request with the updated `argocd/` files via `peter-evans/create-pull-request`.

Required repository secrets:
| Secret | Value |
|--------|-------|
| `ARGOCD_SERVER` | ArgoCD server hostname (no `https://`) |
| `ARGOCD_TOKEN` | ArgoCD API token with `appset-generate` role |

The `appset-generate` role is defined in `argocd/appproj.yaml` and grants read access to applications, applicationsets, clusters, and repositories within the `kargo-addons` project.

---

## RBAC

### ArgoCD

The `kargo-addons` AppProject (`argocd/appproj.yaml`) scopes all addon applications. It includes an `appset-generate` role used by the GitHub Actions token to run `argocd appset generate`.

### Kargo

The `kargo-promote-non-prod` ServiceAccount (`kargo-resources/kube-prometheus-stack/promoteRole.yaml`) allows members of the `argocd-dev` group to trigger promotions to `dev` and `test` stages. It does not grant access to `prod`, which requires manual promotion through the Kargo UI or CLI by a user with appropriate cluster permissions.

---

## Environments

| Environment | Cluster | Auto-promote | Ingress hosts |
|-------------|---------|-------------|---------------|
| `dev` | `dev` | Yes | `*.dev.localhost` |
| `test` | `test` | Yes | `*.test.localhost` |
| `prod` | `prod` | No (manual) | `*.prod.localhost` |

Dev includes a local Prometheus data source configured in Grafana pointing to `http://host.docker.internal:9090` for local development use.

---

## Forking This Repo

A setup script is provided to replace all hardcoded repo URL references after forking.

```bash
./fork-setup.sh https://github.com/your-org/your-repo.git
```

This updates the repo URL in:
- `appsets/kube-prometheus-stack.yaml`
- `argocd/kube-prometheus-stack.yaml`
- `kargo-resources/kube-prometheus-stack/stages.yaml`
- `kargo-resources/kube-prometheus-stack/promotiontask.yaml`

After running the script, complete the following manual steps:

1. **Update cluster names** if your clusters are not named `dev`, `test`, `prod`:
   - `appsets/kube-prometheus-stack.yaml` — `destination.name`
   - `kargo-resources/kube-prometheus-stack/stages.yaml` — `shard`

2. **Add GitHub Actions secrets** to your forked repo:
   | Secret | Value |
   |--------|-------|
   | `ARGOCD_SERVER` | ArgoCD server hostname (no `https://`) |
   | `ARGOCD_TOKEN` | ArgoCD API token with `appset-generate` role |

3. **Commit and push** your changes:
   ```bash
   git add -A && git commit -m "chore: update repo URL for fork"
   git push
   ```

4. **Bootstrap ArgoCD** by applying the bootstrap manifest once:
   ```bash
   kubectl apply -f kargo-addons-bootstrap.yaml
   ```

5. **Regenerate ArgoCD apps** (or let the GitHub Action handle it on push):
   ```bash
   ARGOCD_SERVER=<server> TOKEN=<token> ./generate-apps.sh
   ```
