# Lab 08: Canary with Automated Analysis

## Objectives

* Replace the human gate with **metrics-driven** gates:
  * **background analysis**: a watchdog on the canary's success rate for the whole rollout
  * **inline (step) analysis**: a blocking latency gate at 20% traffic
* Test four scenarios: **good** release (auto-promote), **bad** release (auto-rollback on
  errors), **slow** release (auto-rollback on latency), **borderline** release (inconclusive →
  human decides).
* Use **dry-run** to onboard a metric without risk.

## Concepts

```
step:  0 setWeight 20 │ 1 pause 60s │ 2 analysis(latency-p95) │ 3 setWeight 40 │ ... │ 7 pause 60s
                      │◀───────── background: success-rate-continuous (from step 1 to the end) ─────────▶│
                                  │◀─ blocking gate ─▶│
Any analysis Failed  ⇒ abort: canary → 0, stable → 100%, Rollout Degraded
Inline Inconclusive  ⇒ pause: a human runs promote or abort
All passed           ⇒ canary becomes the new stable
```

`podTemplateHashValue: Latest` resolves to the **canary** ReplicaSet's hash, so the metric
only looks at the new pods' traffic.

## 8.1 Update the Rollout strategy (via Git)

`strategy:` is the last block of `apps/canary-demo/rollout.yaml`, so you can replace it in place:

```bash
cd "$LAB_REPO"
F=apps/canary-demo/rollout.yaml
sed -i '/^  strategy:/,$d' "$F"
cat >> "$F" <<'EOF'
  strategy:
    canary:
      # ---- background analysis: runs from step 1 until the rollout completes ----
      analysis:
        templates:
          - templateName: success-rate-continuous
            clusterScope: true
        startingStep: 1
        args:
          - name: namespace
            value: canary-demo
          - name: pod-template-hash
            valueFrom:
              podTemplateHashValue: Latest
      steps:
        - setWeight: 20
        - pause: { duration: 60s }
        # ---- inline analysis: the rollout blocks here until the run finishes ----
        - analysis:
            templates:
              - templateName: latency-p95
                clusterScope: true
            args:
              - name: namespace
                value: canary-demo
              - name: pod-template-hash
                valueFrom:
                  podTemplateHashValue: Latest
        - setWeight: 40
        - pause: { duration: 60s }
        - setWeight: 60
        - pause: { duration: 60s }
        - setWeight: 80
        - pause: { duration: 60s }
EOF
git add "$F" && git commit -m "canary-demo: automated analysis gates" && git push
argocd app get canary-demo --refresh >/dev/null
```

Changing only `strategy` doesn't change the pod template, so **no rollout starts**. The new
strategy applies to the *next* release. Check with `kubectl argo rollouts get rollout podinfo -n canary-demo`.

Keep the watch running in Terminal 1:

```bash
kubectl argo rollouts get rollout podinfo -n canary-demo --watch
```

Useful inspection commands for every test:

```bash
kubectl -n canary-demo get analysisrun
kubectl -n canary-demo get analysisrun <name> -o jsonpath='{range .status.metricResults[*]}{.name}{"  "}{.phase}{"  ok="}{.successful}{" fail="}{.failed}{" inc="}{.inconclusive}{" err="}{.error}{"\n"}{end}'
kubectl -n canary-demo get analysisrun <name> -o json | jq '.status.metricResults[] | {name, phase, measurements: [.measurements[] | {phase, value}]}'
```

---

## Test 8.1: Good release, fully automatic

```bash
./scripts/release.sh canary-demo 6.16.0 "release-7" good
```

**Expected (≈ 6–7 min):**

| Time | What you should see |
|------|---------------------|
| 0:00 | New revision, 1 canary pod, `SetWeight: 20` |
| 0:00+ | Background AnalysisRun `...-<rev>` **Running** |
| 1:00 | Step 2: a second AnalysisRun (latency) **Running**. The rollout is blocked |
| ~3:00 | Latency run **Successful** → 40% → 60% → 80% |
| ~6:30 | Rollout **Healthy**. Background run ends **Successful** |

No human touched anything. Argo CD shows Progressing → Healthy (never Suspended, because no
step waits for a human).

---

## Test 8.2: Bad release (errors), automatic rollback

```bash
./scripts/release.sh canary-demo 6.17.0 "release-8-buggy" bad
```

**Expected:**

* The canary pod is **Ready**: probes on port 9797 still pass. Kubernetes alone would have
  rolled this out to 100%.
* About 1/3 of the canary's requests fail, so success rate ≈ 0.67 < 0.95.
* The 2nd failed measurement exceeds `failureLimit: 1`, so the background run goes **Failed**
  and the Rollout goes **Degraded / aborted** about 1–1.5 min after the release. Canary is
  scaled to 0.
* Argo CD: app health **Degraded**, sync status **Synced**.

Blast radius: about 20% of users × 33% errors × ~90s. Compare that with a plain Deployment.

```bash
./scripts/sample.sh canary-demo    # 100% "release-7" again
```

**Recover the GitOps way:**

```bash
git revert --no-edit HEAD && git push
argocd app get canary-demo --refresh >/dev/null
# Rollout goes Healthy immediately: the template equals the stable ReplicaSet again
```

---

## Test 8.3: Slow release, rollback on latency

```bash
./scripts/release.sh canary-demo 6.17.0 "release-9-slow" slow
```

**Expected:**

* Background success-rate: **passes** (every request returns 200, just slowly).
* Step 2 latency gate: p95 ≈ 2.4s > 0.6s → **Failed** → abort.
* So each template catches a different class of regression. You need both.

Check it in Prometheus while it runs (query 3 from lab 05): the canary hash's p95 jumps.

Recover:

```bash
git revert --no-edit HEAD && git push
```

---

## Test 8.4: Borderline release, Inconclusive means a human decides

Make the injected latency land **between** the success threshold (0.3s) and the failure
threshold (0.6s): 300–500 ms.

```bash
F=apps/canary-demo/rollout.yaml
sed -i -E '/- name: PODINFO_RANDOM_DELAY_MIN$/{n;s/(value: ).*/\1"300"/}' "$F"
sed -i -E '/- name: PODINFO_RANDOM_DELAY_MAX$/{n;s/(value: ).*/\1"500"/}' "$F"
git add "$F" && git commit -m "tune: delay 300-500ms" && git push
./scripts/release.sh canary-demo 6.17.0 "release-10-meh" slow
```

**Expected:**

* p95 ≈ 0.49s, so every latency measurement is **Inconclusive**.
* After 2 inconclusive results (`inconclusiveLimit: 1`), the run is **Inconclusive** and the
  rollout **pauses** (Argo CD: Suspended).
* You're the release manager now. Pick one:

```bash
kubectl argo rollouts promote podinfo -n canary-demo   # accept and continue
kubectl argo rollouts abort   podinfo -n canary-demo   # reject (then fix Git)
```

Afterwards, put things back:

```bash
sed -i -E '/- name: PODINFO_RANDOM_DELAY_MIN$/{n;s/(value: ).*/\1"800"/}' "$F"
sed -i -E '/- name: PODINFO_RANDOM_DELAY_MAX$/{n;s/(value: ).*/\1"1500"/}' "$F"
git add "$F" && git commit -m "tune: restore delay 800-1500ms" && git push
./scripts/release.sh canary-demo 6.17.0 "release-11" good    # a clean release to finish
```

---

## Test 8.5: Dry-run a metric

You want to *observe* the latency gate before enforcing it. Add `dryRun` to the step analysis:

```bash
# insert dryRun under the inline analysis "templates" list (python keeps YAML indentation exact)
python3 - <<'EOF'
p='apps/canary-demo/rollout.yaml'
s=open(p).read()
old="""              - templateName: latency-p95
                clusterScope: true
"""
new=old+"""            dryRun:
              - metricName: latency-p95
"""
assert old in s; s=s.replace(old,new,1); open(p,'w').write(s)
EOF
git add -A && git commit -m "canary-demo: latency gate in dry-run" && git push
./scripts/release.sh canary-demo 6.17.0 "release-12-slow" slow
```

**Expected:** the latency run records failures but its phase is **Successful**, and the status
message mentions dry-run. The rollout keeps going to 100%, slow release and all. That's the
trade-off of dry-run. Inspect:

```bash
kubectl -n canary-demo get analysisrun -o yaml | grep -iA3 dryRunSummary
```

Then **remove the dryRun block**, commit, and ship a good release to clean up:

```bash
python3 - <<'EOF'
p='apps/canary-demo/rollout.yaml'
s=open(p).read()
s=s.replace("""            dryRun:
              - metricName: latency-p95
""","",1); open(p,'w').write(s)
EOF
git add -A && git commit -m "canary-demo: enforce latency gate" && git push
./scripts/release.sh canary-demo 6.17.0 "release-13" good
```

---

## Results table (fill in yourself)

| Test | Release | Which analysis decided? | Final Rollout state | Time to decision | Recovery |
|------|---------|-------------------------|---------------------|------------------|----------|
| 8.1 | good | | | | n/a |
| 8.2 | bad | | | | |
| 8.3 | slow | | | | |
| 8.4 | borderline | | | | |
| 8.5 | slow (dry-run) | | | | |

## Exercises

1. Make the bad release get caught faster. Which knobs (`initialDelay`, `interval`,
   `failureLimit`, the PromQL `[1m]` window, scrape interval) trade speed for false positives?
2. Move `startingStep` to `0`. What happens to the first measurement when the canary pod isn't
   scraped yet? (Remember the `len(result) > 0` guard.)
3. Add `- analysis: { templates: [{templateName: success-rate, clusterScope: true}], args: [...] }`
   just before `setWeight: 80` as a second blocking gate.

## Checkpoint

- [ ] A good release promoted with **zero** human actions
- [ ] A bad release was rolled back **automatically** and you reverted Git afterwards
- [ ] A slow release was caught by the **latency** gate, not the success-rate one
- [ ] You resolved an **Inconclusive** run by hand

Next: [Lab 09: Blue-green with analysis](09-blue-green-with-analysis.md)
