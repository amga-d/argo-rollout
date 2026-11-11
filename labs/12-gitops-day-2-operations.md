# Lab 12: GitOps Day-2 Operations

Real-world concerns that come up after the first successful canary.

## Objectives

* **Fast rollback** to a recent version (`rollbackWindow`).
* **Stuck releases** (bad image, crash loops) handled by progress deadlines.
* **Argo CD resource actions** for Rollouts (promote/abort from the Argo CD UI/CLI).
* **Real CI** with GitHub Actions committing to the config repo, with no cluster credentials.
* **Disaster recovery**: rebuild the whole cluster from Git.

---

## 12.1 Rollback window: skip the canary when going back

By default, reverting Git to a **previous** version after it was fully replaced is treated as a
brand-new release: it goes through every step and analysis again. That's safe but slow during
an incident. `rollbackWindow` treats "back to one of the last N revisions" as a fast rollback.

### Test 12.1a: without rollbackWindow

```bash
cd "$LAB_REPO"
./scripts/release.sh canary-demo 6.16.0 "release-A" good   # let it finish (~7 min), or promote --full
./scripts/release.sh canary-demo 6.17.0 "release-B" good   # let it finish too
git revert --no-edit HEAD && git push                      # "incident! back to release-A"
kubectl argo rollouts get rollout podinfo -n canary-demo --watch
```

**Expected:** release-A runs the **full canary** again (setWeight 20, analysis, ...).
Promote it with `--full` to move on.

### Test 12.1b: with rollbackWindow

```bash
python3 - <<'EOF'
p='apps/canary-demo/rollout.yaml'
s=open(p).read()
old="  revisionHistoryLimit: 3\n"
new="  revisionHistoryLimit: 3\n  rollbackWindow:\n    revisions: 3     # going back to one of the last 3 revisions skips steps\n"
assert old in s; open(p,'w').write(s.replace(old,new,1))
EOF
git commit -am "canary-demo: rollbackWindow" && git push

./scripts/release.sh canary-demo 6.17.0 "release-C" good   # let it finish
git revert --no-edit HEAD && git push                      # back to the release-A content
```

**Expected:** the rollback is applied **immediately**, without steps. The old ReplicaSet is
scaled up, as a Deployment would do it. Note that `revisionHistoryLimit` must be at least
`rollbackWindow.revisions`, because old ReplicaSets have to exist to roll back to.

---

## 12.2 Progress deadline: releases that never become Ready

```bash
python3 - <<'EOF'
p='apps/canary-demo/rollout.yaml'
s=open(p).read()
old="  revisionHistoryLimit: 3\n"
new="  revisionHistoryLimit: 3\n  progressDeadlineSeconds: 180\n  progressDeadlineAbort: true    # abort (not just mark Degraded) on timeout\n"
assert old in s; open(p,'w').write(s.replace(old,new,1))
EOF
git commit -am "canary-demo: progress deadline abort" && git push
```

### Test 12.2: Image that doesn't exist

```bash
./scripts/release.sh canary-demo 9.9.9 "release-ghost" good
kubectl -n canary-demo get pods -w        # ErrImagePull / ImagePullBackOff
```

**Expected:** analysis never decides anything because the canary has no traffic or metrics.
After 180 s the rollout reports `ProgressDeadlineExceeded` and **aborts**: the canary is
scaled down and stable stays at 100%. Argo CD shows **Degraded**.

```bash
git revert --no-edit HEAD && git push
```

> Without `progressDeadlineAbort`, the rollout is marked Degraded but the broken canary keeps
> retrying forever. Try it.
>
> **Tuning:** keep the deadline longer than any blocking step that makes no replica progress.
> The latency gate takes about 2 min. If a *healthy* release ever reports
> `ProgressDeadlineExceeded`, raise the value.

---

## 12.3 Argo CD resource actions for Rollouts

Argo CD ships Lua **actions** for Rollouts, so release managers can work from the Argo CD
UI without kubectl access. They're a good fit for RBAC (`action/argoproj.io/Rollout/*`).

```bash
./scripts/release.sh canary-demo 6.16.0 "release-D" good
argocd app actions list canary-demo --kind Rollout
# typical: abort, pause, promote-full, restart, resume, retry, skip-current-step (version dependent)
argocd app actions run canary-demo promote-full --kind Rollout --resource-name podinfo
```

In the UI, open the Rollout node in the `canary-demo` app → **⋮ → Actions**.

**Discussion: who presses the button?** With pure analysis gates, nobody. Keep manual
gates (`pause: {}`) for high-risk changes, e.g. a step that needs product sign-off.

---

## 12.4 Real CI: GitHub Actions bumps the config repo

The cluster on your laptop is behind NAT, and it still deploys what GitHub Actions commits
because the cluster **pulls**. GitHub needs no credentials to reach it.

```bash
mkdir -p .github/workflows
cat > .github/workflows/release.yaml <<'EOF'
name: release
on:
  workflow_dispatch:
    inputs:
      app:     { description: "apps/<app>",   required: true, default: canary-demo }
      tag:     { description: "podinfo tag",  required: true, default: "6.16.0" }
      message: { description: "UI message",   required: true, default: "ci-release" }
      mode:
        description: good | bad | slow
        required: true
        default: good
        type: choice
        options: [good, bad, slow]
permissions:
  contents: write            # push to this repo only; no cluster credentials anywhere
concurrency:
  group: release-${{ inputs.app }}
  cancel-in-progress: false
jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # A real pipeline would build, test, scan and push the image here, then bump the tag.
      - name: Bump desired state
        run: |
          git config user.name  "release-bot"
          git config user.email "release-bot@users.noreply.github.com"
          ./scripts/release.sh "${{ inputs.app }}" "${{ inputs.tag }}" "${{ inputs.message }}" "${{ inputs.mode }}"
EOF
git add .github && git commit -m "ci: release workflow" && git push
```

Run it:

```bash
gh workflow run release -f app=canary-demo -f tag=6.17.0 -f message=from-github-actions -f mode=good
gh run watch
git pull --rebase       # your local clone needs the bot's commit too
```

**Expected:** a commit by `release-bot` lands on `main`, and about a minute later the canary
starts in your cluster.

> **Remember** to `git pull --rebase` before running `release.sh` locally from now on, or your
> push gets rejected. That's normal life with bot commits in a config repo.

**Further reading / next steps:** Argo CD Image Updater can bump tags automatically when a
registry gets a new image. Kargo adds multi-stage promotion (dev → staging → prod) on top of Argo CD.

---

## 12.5 Multi-environment promotion (design exercise)

Restructure one app as Kustomize base + overlays:

```
apps-envs/podinfo/
├── base/            rollout.yaml, service.yaml, podmonitor.yaml, kustomization.yaml
└── overlays/
    ├── staging/     kustomization.yaml  (namespace: podinfo-staging-demo, images: tag X, fewer steps)
    └── prod/        kustomization.yaml  (namespace: podinfo-prod-demo,   images: tag Y, full analysis)
```

* Promotion = a PR that copies the tag from `staging` to `prod`.
* Point a second ApplicationSet generator at `apps-envs/*/overlays/*`.
* Question: should staging use the same analysis thresholds as prod? (Usually not: less
  traffic means noisier metrics, so use longer windows or Job-based tests.)

> Kustomize tip: for `images:` to rewrite Rollout containers, add the Argo Rollouts Kustomize
> openapi/configurations described in the Argo Rollouts docs ("Kustomize Integration"), or patch
> the image explicitly.

---

## 12.6 Disaster recovery drill: rebuild the cluster from Git

This drill shows what GitOps buys you most clearly.

```bash
minikube delete -p rollouts-lab
minikube start -p rollouts-lab --driver=docker --cpus=4 --memory=6144 --disk-size=30g
minikube -p rollouts-lab addons enable metrics-server

helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.17.2 -f "$LAB_REPO/bootstrap/argocd-values.yaml" --wait
kubectl apply -f "$LAB_REPO/bootstrap/root-app.yaml"
# (private repo? re-add the credentials first: lab 03, section 3.5)

watch -n5 'kubectl -n argocd get applications'
```

**Expected:** in 5–10 minutes every platform component, the analysis library, the gateway and
all three demo apps come back on their **last released versions**. You ran 3 commands. Time it.

What did **not** come back? Prometheus history, Grafana dashboards you built in the UI, and the
Argo CD admin password. Ask yourself which of those belong in Git (dashboards: yes, as
ConfigMaps) and which need backups or external storage.

## Checkpoint

- [ ] You saw a full-canary rollback vs an instant `rollbackWindow` rollback
- [ ] An unpullable image aborted automatically through `progressDeadlineAbort`
- [ ] You promoted a rollout through an **Argo CD action**
- [ ] (Optional) a GitHub Actions run deployed to your laptop cluster
- [ ] (Optional) you rebuilt the cluster from Git

Next: [Lab 13: Troubleshooting, cheat sheet & cleanup](13-troubleshooting-and-cleanup.md)
