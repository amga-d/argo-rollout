# Lab 09: Blue-Green with Pre- and Post-Promotion Analysis

## Objectives

* Deploy a second app, `bluegreen-demo`, using the **blueGreen** strategy. You just add a folder
  and the ApplicationSet does the rest.
* Gate the switch with **pre-promotion analysis** (Job smoke test + Prometheus on preview traffic).
* Protect the time after the switch with **post-promotion analysis**, which switches traffic
  back to the old version if it fails.
* Compare the blast radius with canary.

## Concepts

```
            podinfo-active  ─────▶ blue RS  (100% of users)
 release ─▶ podinfo-preview ─────▶ green RS (testers / smoke tests / synthetic traffic only)
            │
            ├─ prePromotionAnalysis  (green, before it gets any user traffic)
            │     fail ⇒ abort: users never saw green
            ├─ promote: active selector ⇒ green   (all users at once)
            ├─ postPromotionAnalysis (green, with real traffic)
            │     fail ⇒ abort: active selector ⇒ back to blue (still running)
            └─ after scaleDownDelaySeconds: blue scaled to 0
```

| | Canary | Blue-green |
|--|--------|-----------|
| Users exposed during verification | a % of users | **none** (pre-promotion) |
| Exposure after promotion | gradual | **100% at once** |
| Extra capacity | small (canary pods) | **2×** during the release |
| Rollback | scale canary down | flip the selector back (instant, while blue is alive) |
| Good fit for | stateless services with plenty of traffic | apps needing full-version testing, or where mixing versions is unsafe |

The controller manages both Services by injecting `rollouts-pod-template-hash` into their
selectors. **Don't** put that label in Git yourself.

## 9.1 Create the app

```bash
cd "$LAB_REPO"
mkdir -p apps/bluegreen-demo
```

```bash
cat > apps/bluegreen-demo/rollout.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: podinfo
  labels:
    app: podinfo
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.15.0
          ports:
            - name: http
              containerPort: 9898
            - name: http-metrics
              containerPort: 9797
          env:
            # --- release-controlled values (edited by scripts/release.sh) ---
            - name: PODINFO_UI_MESSAGE
              value: "blue-1"
            - name: PODINFO_RANDOM_ERROR
              value: "false"
            - name: PODINFO_RANDOM_DELAY
              value: "false"
            # --- static config ---
            - name: PODINFO_PORT_METRICS
              value: "9797"
            - name: PODINFO_RANDOM_DELAY_UNIT
              value: "ms"
            - name: PODINFO_RANDOM_DELAY_MIN
              value: "800"
            - name: PODINFO_RANDOM_DELAY_MAX
              value: "1500"
          readinessProbe:
            httpGet: { path: /healthz, port: http-metrics }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: http-metrics }
            initialDelaySeconds: 5
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { memory: 128Mi }
  strategy:
    blueGreen:
      activeService: podinfo-active
      previewService: podinfo-preview
      autoPromotionEnabled: false        # Test 9.1: a human approves. Flipped in Test 9.2
      scaleDownDelaySeconds: 600         # keep blue alive 10 min after the switch (fast rollback)
      prePromotionAnalysis:
        templates:
          - templateName: smoke-test
            clusterScope: true
          - templateName: success-rate
            clusterScope: true
        args:
          - name: service-url
            value: http://podinfo-preview.bluegreen-demo.svc.cluster.local
          - name: namespace
            value: bluegreen-demo
          - name: pod-template-hash
            valueFrom:
              podTemplateHashValue: Latest
      postPromotionAnalysis:
        templates:
          - templateName: success-rate
            clusterScope: true
          - templateName: latency-p95
            clusterScope: true
        args:
          - name: namespace
            value: bluegreen-demo
          - name: pod-template-hash
            valueFrom:
              podTemplateHashValue: Latest
EOF
```

```bash
cat > apps/bluegreen-demo/services.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: podinfo-active
spec:
  selector:
    app: podinfo           # the controller adds rollouts-pod-template-hash=<active hash>
  ports:
    - { name: http, port: 80, targetPort: http }
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo-preview
spec:
  selector:
    app: podinfo           # the controller adds rollouts-pod-template-hash=<preview hash>
  ports:
    - { name: http, port: 80, targetPort: http }
EOF

cat > apps/bluegreen-demo/podmonitor.yaml <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: podinfo
spec:
  selector:
    matchLabels: { app: podinfo }
  podMetricsEndpoints:
    - port: http-metrics
      interval: 10s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_label_rollouts_pod_template_hash]
          targetLabel: rollouts_pod_template_hash
EOF

cat > apps/bluegreen-demo/loadgen.yaml <<'EOF'
# 3 "users" on the active service + 1 synthetic client on preview, so
# pre-promotion Prometheus analysis has traffic to look at.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgen
spec:
  replicas: 1
  selector:
    matchLabels: { app: loadgen }
  template:
    metadata:
      labels: { app: loadgen }
    spec:
      containers:
        - name: loadgen
          image: curlimages/curl:8.17.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              worker() { while true; do curl -s -o /dev/null --max-time 5 "$1"; sleep 0.2; done; }
              for i in 1 2 3; do worker http://podinfo-active.bluegreen-demo.svc.cluster.local/ & done
              worker http://podinfo-preview.bluegreen-demo.svc.cluster.local/ &
              wait
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { memory: 64Mi }
EOF

git add apps/bluegreen-demo && git commit -m "apps: bluegreen-demo" && git push
argocd app get root --refresh >/dev/null
```

**Expected:** within about 1–2 min (ApplicationSet requeue + Argo CD poll) a `bluegreen-demo`
Application appears. First deploy: blue-1 is active right away, without analysis.

```bash
kubectl argo rollouts get rollout podinfo -n bluegreen-demo --watch     # Terminal 1
kubectl -n bluegreen-demo get svc -o custom-columns=NAME:.metadata.name,SELECTOR:.spec.selector
```

---

## Test 9.1: Good release with manual approval

```bash
./scripts/release.sh bluegreen-demo 6.16.0 "green-2" good
```

**Expected:**

1. A second ReplicaSet (`preview`) comes up with 3 pods. Users still hit blue-1.
2. A pre-promotion AnalysisRun with **two metrics** (Job `smoke-test` and `success-rate`)
   finishes **Successful** after about 2–2.5 min.
3. Rollout status `॥ Paused` (`BlueGreenPause`), Argo CD **Suspended**: waiting for you.

Do some manual QA on the preview, as a tester would:

```bash
./scripts/sample.sh bluegreen-demo http://podinfo-preview 20     # all "green-2"
./scripts/sample.sh bluegreen-demo http://podinfo-active  20     # all "blue-1"
kubectl -n bluegreen-demo port-forward svc/podinfo-preview 9898:80   # open http://localhost:9898
```

Approve:

```bash
kubectl argo rollouts promote podinfo -n bluegreen-demo
```

**Expected:** active flips to green-2 **at once**, post-promotion analysis runs (≈ 2.5 min)
and ends **Successful**, and the old ReplicaSet stays up with a scale-down countdown
(`kubectl -n bluegreen-demo get rs`). It disappears after 10 min.

---

## Test 9.2: Bad release, stopped before any user sees it

Turn on auto-promotion. From now on the analysis is the only gate:

```bash
sed -i 's/autoPromotionEnabled: false .*/autoPromotionEnabled: true         # analysis is the only gate/' \
  apps/bluegreen-demo/rollout.yaml
git commit -am "bluegreen-demo: auto-promote after pre-promotion analysis" && git push

./scripts/release.sh bluegreen-demo 6.17.0 "green-3-buggy" bad
```

**Expected:**

* The `smoke-test` Job fails within seconds (30 requests at a 1/3 error rate). Find it with
  `kubectl -n bluegreen-demo get jobs`, then read its output with
  `kubectl -n bluegreen-demo logs job/<job-name>`.
* The pre-promotion run goes **Failed**, the rollout **aborts**, the preview is scaled down,
  and **active never changed**.
* Blast radius for real users: **zero**.

```bash
./scripts/sample.sh bluegreen-demo http://podinfo-active 20      # still "green-2"
git revert --no-edit HEAD && git push                             # restore Git = truth
```

---

## Test 9.3: Slow release, passes pre-promotion, caught after the switch

```bash
./scripts/release.sh bluegreen-demo 6.17.0 "green-4-slow" slow
```

**Expected:**

1. Pre-promotion passes: the smoke test only checks status codes, and success rate is 100%.
   The bug slips through, as real bugs sometimes do.
2. **Auto-promotion**: active → green-4-slow. Users now see about 1–2s latency.
3. Post-promotion `latency-p95` fails (p95 ≈ 2.4s) → **abort** → the active Service selector
   is switched **back** to green-2, which is still running thanks to `scaleDownDelaySeconds`.

Verify which ReplicaSet the active Service points at:

```bash
kubectl -n bluegreen-demo get svc podinfo-active -o jsonpath='{.spec.selector}{"\n"}'
kubectl -n bluegreen-demo get rs -L rollouts-pod-template-hash
./scripts/sample.sh bluegreen-demo http://podinfo-active 20      # "green-2" again
```

Recover Git:

```bash
git revert --no-edit HEAD && git push
```

> **Lesson:** pre-promotion analysis only sees what you test or what synthetic traffic produces.
> Post-promotion analysis with real traffic is your second line of defence, and it only works
> while the old version is still running. Choose `scaleDownDelaySeconds` to cover the whole
> post-promotion analysis.

---

## Exercises

1. Set `previewReplicaCount: 1`. The preview runs with 1 pod and scales to full size only at
   promotion. What does that save, and what risk does it add?
2. Replace manual approval with a timer: `autoPromotionEnabled: true` plus
   `autoPromotionSeconds: 120`. How does it interact with pre-promotion analysis?
3. Add the `http-health` (web provider) template to `prePromotionAnalysis` with
   `service-url: http://podinfo-preview.bluegreen-demo.svc.cluster.local`. Does it catch the
   bad release? (Hint: `/healthz` on the **main** port *is* affected by injected errors.)
4. Set `scaleDownDelaySeconds: 30` and repeat Test 9.3. What happens to the rollback?

## Checkpoint

- [ ] Manual approval: preview tested, promoted, post-promotion analysis Successful
- [ ] Bad release aborted **before** the switch; active was never touched
- [ ] Slow release switched, then was rolled back by post-promotion analysis
- [ ] You can explain when to choose blue-green over canary

Next: [Lab 10: Canary with traffic routing (Gateway API)](10-canary-traffic-routing-gateway-api.md)
