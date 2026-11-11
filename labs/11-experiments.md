# Lab 11: Experiments (Baseline vs Canary)

## Objectives

* Use an **Experiment** step to run a fresh *baseline* (current version) and a fresh *canary*
  (new version) side by side, and compare them with **one** analysis.
* Understand why comparing against a fresh baseline beats comparing against fixed thresholds.

## Concepts

A fixed threshold ("success rate ≥ 95%") ignores context. If the whole system is at 93% today
because a dependency is down, every release fails. If normal is 99.9%, a canary at 96% still
passes. An experiment compares like with like: the **same number of fresh pods**, started at
the same time, under the same traffic, differing only in version.

```
step 0: experiment (3m)
          ├─ ReplicaSet "baseline" (specRef: stable) 1 pod ┐ own pod-template-hashes,
          ├─ ReplicaSet "canary"   (specRef: canary) 1 pod ┘ separate from the Rollout's RSs
          └─ AnalysisRun canary-vs-baseline(baseline-hash, canary-hash)
        failed ⇒ the rollout aborts before setWeight runs
step 1: setWeight 20 ... (as in lab 08)
```

> **Traffic note:** in `canary-demo` the Service selects `app: podinfo`, so the experiment pods
> get a share of real traffic (about 1/7 each with 5 stable pods). With a traffic router you'd
> give experiment templates a `weight` or a dedicated Service instead.

## 11.1 The comparison template

```bash
cd "$LAB_REPO"
cat > analysis/canary-vs-baseline.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: canary-vs-baseline
spec:
  args:
    - name: namespace
    - name: baseline-hash
    - name: canary-hash
  metrics:
    - name: success-rate-delta
      initialDelay: 45s
      interval: 30s
      count: 4
      failureLimit: 1
      # canary success rate minus baseline success rate; allow 2 points of noise
      successCondition: len(result) > 0 && !isNaN(result[0]) && result[0] >= -0.02
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: |
            (
              sum(rate(http_requests_total{namespace="{{args.namespace}}",rollouts_pod_template_hash="{{args.canary-hash}}",status=~"2.."}[1m]))
              /
              sum(rate(http_requests_total{namespace="{{args.namespace}}",rollouts_pod_template_hash="{{args.canary-hash}}"}[1m]))
            )
            -
            (
              sum(rate(http_requests_total{namespace="{{args.namespace}}",rollouts_pod_template_hash="{{args.baseline-hash}}",status=~"2.."}[1m]))
              /
              sum(rate(http_requests_total{namespace="{{args.namespace}}",rollouts_pod_template_hash="{{args.baseline-hash}}"}[1m]))
            )
EOF
git add analysis && git commit -m "analysis: canary-vs-baseline" && git push
```

## 11.2 Add an experiment step to canary-demo

```bash
python3 - <<'EOF'
p='apps/canary-demo/rollout.yaml'
s=open(p).read()
old="""      steps:
        - setWeight: 20
"""
new="""      steps:
        - experiment:
            duration: 3m
            templates:
              - name: baseline
                specRef: stable
                replicas: 1
              - name: canary
                specRef: canary
                replicas: 1
            analyses:
              - name: compare
                templateName: canary-vs-baseline
                clusterScope: true
                args:
                  - name: namespace
                    value: canary-demo
                  - name: baseline-hash
                    value: "{{templates.baseline.podTemplateHash}}"
                  - name: canary-hash
                    value: "{{templates.canary.podTemplateHash}}"
        - setWeight: 20
"""
assert old in s; s=s.replace(old,new,1)
# the background analysis should still start at the pause after setWeight 20 (now index 2)
s=s.replace("        startingStep: 1\n","        startingStep: 2\n",1)
s=s.replace("runs from step 1 until","runs from step 2 until",1)
open(p,'w').write(s)
EOF
git add -A && git commit -m "canary-demo: experiment step (baseline vs canary)" && git push
argocd app get canary-demo --refresh >/dev/null
```

---

## Test 11.1: Good release passes the experiment

```bash
./scripts/release.sh canary-demo 6.16.0 "release-14" good
kubectl argo rollouts get rollout podinfo -n canary-demo --watch
```

**Expected:**

```bash
kubectl argo rollouts list experiments -n canary-demo
kubectl argo rollouts get experiment <name> -n canary-demo
kubectl -n canary-demo get rs -L rollouts-pod-template-hash   # two extra 1-pod ReplicaSets
```

* The experiment creates `...-baseline` and `...-canary` ReplicaSets with **their own hashes**.
* The `compare` run shows deltas near `0` and goes **Successful**.
* After 3 min the experiment pods are removed and the rollout continues at `setWeight: 20`.

## Test 11.2: Bad release fails the comparison

```bash
./scripts/release.sh canary-demo 6.17.0 "release-15-buggy" bad
```

**Expected:** delta ≈ −0.33 → **Failed** → the experiment fails → the **rollout aborts before
step 1**, and the Rollout's own canary ReplicaSet never gets a `setWeight`.

```bash
git revert --no-edit HEAD && git push
```

## Test 11.3: Why relative beats absolute (thought experiment + practice)

1. Temporarily make the *stable* version noisy: run `./scripts/release.sh canary-demo 6.16.0 "noisy-stable" bad`,
   then `kubectl argo rollouts promote podinfo -n canary-demo --full`. You're forcing a bad
   version to become stable, which you'd never do in production.
2. Release an *identical* noisy version with a different message:
   `./scripts/release.sh canary-demo 6.16.0 "noisy-stable-2" bad`.
3. Observe: `canary-vs-baseline` **passes** (delta ≈ 0), but the background
   `success-rate-continuous` **fails** (absolute 0.67 < 0.95).
4. Discuss: which answer is right depends on what you're asking. "Is this release *worse* than
   what's running?" (relative) or "Is the service *healthy*?" (absolute). Mature setups use both.
5. Clean up: `./scripts/release.sh canary-demo 6.16.0 "release-16" good`, then
   `kubectl argo rollouts promote podinfo -n canary-demo --full` if it gets stuck.

## Clean up the experiment step (optional)

To keep later labs fast, revert the experiment commit:

```bash
git log --oneline | grep 'experiment step'      # find the commit
git revert --no-edit <sha> && git push
```

## Exercises

1. Add a latency comparison metric to `canary-vs-baseline`: canary p95 / baseline p95 ≤ 1.5.
2. Replace `duration: 3m` with `requiredForCompletion: true` on the analysis. What ends the
   experiment now?
3. Run an Experiment **on its own** (`kind: Experiment`) in a sandbox to compare two arbitrary
   images, for example for a load-testing bake-off.

## Checkpoint

- [ ] You saw baseline and canary ReplicaSets with their own hashes
- [ ] A bad release failed the comparison and the rollout aborted at step 0
- [ ] You can explain when relative (baseline) analysis beats absolute thresholds, and the reverse

Next: [Lab 12: GitOps day-2 operations](12-gitops-day-2-operations.md)
