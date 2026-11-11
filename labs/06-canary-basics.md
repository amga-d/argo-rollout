# Lab 06: Canary Basics (Manual Gates)

## Objectives

* Run a canary release triggered **only by a Git commit**.
* Use the Rollout lifecycle commands: promote, promote `--full`, abort, retry.
* See how each Rollout state appears in **Argo CD**, and why Git must stay the source of truth
  after an abort.

## Concepts

```
 Git commit ─▶ Argo CD sync ─▶ Rollout spec changes ─▶ new ReplicaSet (canary)
                                                    │
     step 0  setWeight 20   ─ canary 1 pod, stable 4 pods (replica-ratio split)
     step 1  pause {}       ─ Rollout "Paused"  => Argo CD health "Suspended"
                 └── kubectl argo rollouts promote ──┐
     step 2  setWeight 50   ◀─────────────────────────┘
     step 3  pause 60s
     step 4  setWeight 80
     step 5  pause 60s
     done ─ canary RS becomes stable, old RS scaled to 0
```

| Rollout status | Argo CD health | Meaning |
|----------------|----------------|---------|
| Healthy | Healthy | Fully promoted |
| Progressing | Progressing | Moving between steps |
| Paused | **Suspended** | Waiting for a timer or a human |
| Degraded (Aborted) | **Degraded** | Canary rejected. Stable gets 100% traffic, but Git still declares the rejected version |

Without a traffic router, `setWeight: 20` means "about 20% of the **pods** are canary". With 5
replicas you can only get 0/20/40/60/80/100% (lab 10 removes that limit).

Keep two terminals open during this lab:

```bash
# Terminal 1: live view of the rollout
kubectl argo rollouts get rollout podinfo -n canary-demo --watch
# Terminal 2: run commands (cd "$LAB_REPO")
```

Also open the Rollouts dashboard (<http://localhost:3100/rollouts/canary-demo>) and the Argo CD
UI for `canary-demo`.

---

## Test 6.1: A normal canary release, promoted by hand

```bash
cd "$LAB_REPO"
./scripts/release.sh canary-demo 6.16.0 "release-2"
argocd app get canary-demo --refresh >/dev/null   # skip the polling wait (optional)
```

**Observe:**

1. Argo CD: `OutOfSync` → sync → app health **Suspended**.
2. Terminal 1: `Step: 1/6`, `SetWeight: 20`, a new revision with 1 pod, `Status: ॥ Paused`.
3. Traffic split:

   ```bash
   ./scripts/sample.sh canary-demo     # ≈ 80 "release-1" / 20 "release-2"
   ```

4. Prometheus query 1 from lab 05 now shows **two** hash series.

**Promote** past the indefinite pause:

```bash
kubectl argo rollouts promote podinfo -n canary-demo
```

The timed pauses then advance automatically: 50% → 60s → 80% → 60s → **✔ Healthy**. The old
ReplicaSet scales to 0 after the default `scaleDownDelaySeconds` (30s).

**Expected result:** `release-2` serves 100%; Argo CD shows Synced/Healthy.

---

## Test 6.2: Abort a release, then fix Git

```bash
./scripts/release.sh canary-demo 6.16.0 "release-3"
# wait until Terminal 1 shows "Paused" at step 1
kubectl argo rollouts abort podinfo -n canary-demo
```

**Observe:**

* The canary scales to 0 and stable (`release-2`) gets 100%. Users are safe.
* Rollout: `✖ Degraded`, message `RolloutAborted`. Argo CD app health: **Degraded**.
* Argo CD sync status stays **Synced**. Git says `release-3`, and the Rollout *spec* does too;
  only the controller refuses to finish it.

**Question:** what is the "truth" now? Git says release-3, the cluster serves release-2.
That's an inconsistent state, and GitOps says to fix it **in Git**:

```bash
git revert --no-edit HEAD && git push
argocd app get canary-demo --refresh >/dev/null
```

**Expected result:** the Rollout's template now matches the stable ReplicaSet again, so the
controller marks it **Healthy immediately, without running the steps**. Going back to the
current stable version is always instant.

> Alternative: `kubectl argo rollouts retry rollout podinfo -n canary-demo` restarts the *same*
> canary from step 0. Use it when the abort was a false alarm.

---

## Test 6.3: Emergency fast-track (`promote --full`)

```bash
./scripts/release.sh canary-demo 6.16.0 "release-4-hotfix"
# at the first pause:
kubectl argo rollouts promote podinfo -n canary-demo --full
```

**Expected result:** all remaining steps are skipped and the canary goes straight to 100%.
This is the "hotfix, I accept the risk" path.

---

## Test 6.4: A new commit lands mid-rollout

```bash
./scripts/release.sh canary-demo 6.16.0 "release-5"
# while it is paused at 20%:
./scripts/release.sh canary-demo 6.16.0 "release-6"
```

**Expected result:** the `release-5` canary ReplicaSet is scaled down and abandoned. `release-6`
starts again from step 0, measured against the **stable** version (`release-4-hotfix`), not
against the half-finished canary. Promote to finish:

```bash
kubectl argo rollouts promote podinfo -n canary-demo --full
```

---

## Test 6.5: Why not change the Rollout with kubectl? (anti-pattern drill)

```bash
# (cluster) someone "helps" by setting the image by hand
kubectl argo rollouts set image podinfo -n canary-demo podinfo=ghcr.io/stefanprodan/podinfo:6.17.0
```

**Observe:** a canary starts, and within seconds Argo CD self-heal sees that the live spec ≠ Git
and reverts the image. The Rollout returns to stable instantly, as in test 6.2.

**Lesson:** imperative *spec* changes (`set image`, `undo`, `kubectl edit`) fight GitOps.
Imperative *lifecycle* commands (`promote`, `abort`, `retry`, `pause`) are fine. They act on
status and pause conditions, not on the declared desired state.

> Check this yourself: after `kubectl argo rollouts promote`, does Argo CD report `OutOfSync`?
> (It shouldn't.)

---

## Exercises

1. Replace `pause: {}` with `pause: { duration: 2m }` (commit and push) and release again. No
   human is needed now, but there's no safety net either. Lab 08 adds one.
2. Set `replicas: 10` and steps `setWeight: 10/30/50`. Check the canary pod counts with
   `kubectl -n canary-demo get rs`.
3. Add `maxSurge: "100%"` under `canary:` and watch how many pods exist during a step.
   (Default is 25%.)

## Checkpoint

- [ ] You promoted a release by hand and saw Argo CD **Suspended** while paused
- [ ] You aborted a release and recovered by **reverting in Git**
- [ ] You can explain why `promote` is GitOps-safe and `set image` is not

Next: [Lab 07: Analysis templates](07-analysis-templates.md)
