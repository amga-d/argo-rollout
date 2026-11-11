# Progressive Delivery Lab: Argo CD + Argo Rollouts (GitOps, pull-based)

A hands-on lab that builds a small but realistic progressive-delivery platform on a local
Kubernetes cluster. You start from an empty machine and end up running canary, blue-green,
traffic-routed canary and experiment-based releases. Each one is gated by automated analysis
on real Prometheus metrics, and every change reaches the cluster **only through Git**.

```
 ┌──────────────┐  git push   ┌──────────────────────────┐
 │ You / "CI"   │ ──────────▶ │ GitHub: rollouts-gitops- │
 │ release.sh   │             │ lab (desired state)      │
 └──────────────┘             └────────────┬─────────────┘
                                           │  Argo CD PULLS (polls every 60s)
                                           ▼  (the cluster is never pushed to)
 ┌──────────────────────── minikube profile: rollouts-lab ─────────────────────────┐
 │                                                                                │
 │  argocd ─────────────▶ root app (app-of-apps) ──▶ platform Applications         │
 │                          │                           ├─ argo-rollouts (+dash)  │
 │                          │                           ├─ kube-prometheus-stack  │
 │                          │                           ├─ analysis-library       │
 │                          │                           ├─ envoy-gateway (lab 10) │
 │                          │                           └─ ApplicationSet ──▶ apps/*
 │                          ▼                                                     │
 │   canary-demo / bluegreen-demo / traffic-demo namespaces                       │
 │     Rollout(podinfo) ─▶ ReplicaSets (stable / canary)   ◀── loadgen traffic    │
 │          │                     │ /metrics                                      │
 │          │ AnalysisRun         ▼                                               │
 │          └────────────▶ Prometheus (PodMonitor, label rollouts_pod_template_hash)
 │                         promote ✔  /  abort + rollback ✘                       │
 └────────────────────────────────────────────────────────────────────────────────┘
```

## What you will learn

| Area | Topics |
|------|--------|
| GitOps | Pull vs push, app-of-apps, AppProjects, ApplicationSet, sync waves, self-heal, prune, drift, `ignoreDifferences` |
| Argo Rollouts | Rollout CRD, canary steps, pause/promote/abort/retry, blue-green, preview/active services, traffic routing with the Gateway API plugin, header routing, experiments, rollback window |
| Analysis | AnalysisTemplate vs ClusterAnalysisTemplate, AnalysisRun, Prometheus/Job/Web providers, args, `podTemplateHashValue`, background vs inline analysis, pre/post-promotion analysis, inconclusive results, dry-run |
| Observability | kube-prometheus-stack, PodMonitor relabeling, PromQL for success rate and p95 latency per ReplicaSet |
| Real-world ops | Simulated CI that commits to Git, rollback with `git revert`, failed-release drills, progress deadlines, CI from GitHub Actions without cluster credentials |

## Lab map

| # | Lab | You will end with |
|---|-----|-------------------|
| 01 | [Prerequisites & cluster](labs/01-prerequisites-and-cluster.md) | A dedicated minikube profile with the tooling verified |
| 02 | [GitOps repository](labs/02-gitops-repository.md) | A GitHub repo with the layout Argo CD will pull from |
| 03 | [Argo CD bootstrap](labs/03-argocd-bootstrap.md) | Argo CD installed, plus a root app-of-apps |
| 04 | [Platform services](labs/04-platform-services.md) | Argo Rollouts, its dashboard, Prometheus and Grafana, all installed through Git |
| 05 | [Workload & observability](labs/05-workload-and-observability.md) | podinfo as a Rollout, load generator, per-ReplicaSet metrics, release script |
| 06 | [Canary basics (manual gates)](labs/06-canary-basics.md) | Steps, pauses, promote, abort, retry, and how each looks in Argo CD |
| 07 | [Analysis templates](labs/07-analysis-templates.md) | A reusable analysis library, tested on its own |
| 08 | [Canary + automated analysis](labs/08-canary-with-analysis.md) | Automatic promotion and automatic rollback (bad and slow releases) |
| 09 | [Blue-green + analysis](labs/09-blue-green-with-analysis.md) | Pre-/post-promotion gates, preview testing, rollback after the switch |
| 10 | [Canary with traffic routing (Gateway API)](labs/10-canary-traffic-routing-gateway-api.md) | Exact weights, header routing for QA, Envoy Gateway |
| 11 | [Experiments (baseline vs canary)](labs/11-experiments.md) | A/B comparison with an Experiment step |
| 12 | [GitOps day-2 operations](labs/12-gitops-day-2-operations.md) | Rollback window, progress deadlines, Argo CD actions, CI with GitHub Actions |
| 13 | [Troubleshooting, cheat sheet & cleanup](labs/13-troubleshooting-and-cleanup.md) | Debug playbook and teardown |

Do the labs in order. Each one builds on the state left by the previous one.

## Versions used when writing this lab (Nov 2026)

| Component | Version | Notes |
|-----------|---------|-------|
| minikube | v1.39.0 | Dedicated profile `rollouts-lab` |
| kubectl | v1.37 | |
| Helm | v3.16 | Used only for the Argo CD bootstrap |
| Argo CD Helm chart (`argo/argo-cd`) | 10.17.2 (app v3.6.1) | |
| Argo Rollouts Helm chart (`argo/argo-rollouts`) | 2.43.12 (app v1.10.2) | |
| kubectl-argo-rollouts plugin | v1.10.x | |
| kube-prometheus-stack | 93.2.0 | |
| Envoy Gateway (`oci://docker.io/envoyproxy/gateway-helm`) | v1.10.0 | Bundles the Gateway API CRDs |
| Gateway API traffic-router plugin | v0.17.0 | |
| podinfo (sample app) | 6.15.0 → 6.16.0 → 6.17.0 | `ghcr.io/stefanprodan/podinfo` |

> Newer versions will probably work, but **pin versions in Git**. That's half the point of
> GitOps. Run `helm search repo <chart> --versions` to see what exists.

## Why podinfo?

[podinfo](https://github.com/stefanprodan/podinfo) has three properties that make it a good
stand-in for a real service:

* It exposes Prometheus metrics (`http_requests_total{status}`,
  `http_request_duration_seconds_bucket{path,status}`) on a **separate metrics port (9797)**.
* It can inject failures through environment variables, so a "bad release" is a one-line Git change:
  * `PODINFO_RANDOM_ERROR=true` makes about 1/3 of requests fail with 400/409/500.
  * `PODINFO_RANDOM_DELAY=true` (plus `_MIN` / `_MAX` / `_UNIT`) adds latency.
* Its health endpoint on the metrics port is **not** affected by the injected errors, so a bad
  release still becomes Ready. The bug only shows in business metrics, as most real bad
  releases do. That's the gap analysis is meant to catch.

## Conventions used in the labs

* `$LAB_REPO` is the local clone of your GitOps repository (created in lab 02).
* `YOUR_GH_USER` is a placeholder in YAML. Lab 02 shows a one-liner that replaces it.
* Shell blocks marked `# (cluster)` change the cluster directly. They are deliberate
  exceptions (bootstrap, debugging, drills). Everything else goes through `git push`.
* Every lab ends with a **Checkpoint**. Don't move on until it is green.
