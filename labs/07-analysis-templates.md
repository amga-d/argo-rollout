# Lab 07: Analysis Templates (the SRE Library)

## Objectives

* Understand AnalysisTemplate, ClusterAnalysisTemplate and AnalysisRun, and every important metric field.
* Build a reusable, Git-managed library of **ClusterAnalysisTemplates**:
  * `success-rate`: finite gate (Prometheus)
  * `success-rate-continuous`: background watchdog (Prometheus, no `count`)
  * `latency-p95`: finite gate (Prometheus)
  * `smoke-test`: functional test (Kubernetes **Job** provider)
  * `http-health`: endpoint check (**Web** provider)
* **Test each template on its own** before trusting it with a release.

## Concepts

```
ClusterAnalysisTemplate (cluster-wide)     AnalysisTemplate (namespaced)
            │  referenced by a Rollout step / background / pre/post-promotion
            ▼
      AnalysisRun  (created by the controller, owned by the Rollout)
         └── metrics[] ── measurements[] ── each one: Successful | Failed | Inconclusive | Error
```

### Metric fields you must know

| Field | Meaning | Default |
|-------|---------|---------|
| `provider` | Where the value comes from (`prometheus`, `job`, `web`, `datadog`, `newRelic`, `cloudWatch`, `kayenta`, plugins, ...) | |
| `interval` | Time between measurements | run once |
| `count` | Number of measurements. **Unset = run until the rollout finishes** (background only) | 1 if no interval |
| `initialDelay` | Wait before the first measurement (let the new pods warm up and get scraped) | 0 |
| `successCondition` / `failureCondition` | `expr` expressions over `result` | |
| `failureLimit` | How many **Failed** measurements are tolerated. Exceeding it fails the run | 0 |
| `inconclusiveLimit` | How many **Inconclusive** measurements are tolerated | 0 |
| `consecutiveErrorLimit` | How many **Error**s in a row are tolerated (e.g. Prometheus unreachable) | 4 |

**Outcome of a run:**

* **Successful**: the step advances, or promotion happens.
* **Failed**: the rollout **aborts** and goes back to stable.
* **Inconclusive**: the rollout **pauses** and a human decides (`promote` or `abort`). You get
  this when a value meets neither the success nor the failure condition.

**Args** make templates reusable: `{{args.namespace}}`, `{{args.pod-template-hash}}`. A Rollout
supplies them, and `valueFrom.podTemplateHashValue: Latest | Stable` injects the canary or
stable ReplicaSet hash.

> Safe rule for this lab: use `{{args.*}}` in **provider fields** (query, url, job spec) and
> keep thresholds as literals in the conditions. That's the documented, portable pattern.

### Prometheus `result` shape

The query returns an instant vector, so `result` is a list: `result[0]` is the first sample.
An **empty** result (no series yet) or **NaN** (0/0 when there's no traffic) has to be handled
explicitly. Otherwise you get Errors, or false successes.

## 7.1 Write the templates

```bash
cd "$LAB_REPO"
rm -f analysis/.gitkeep
```

### success-rate (finite gate)

```bash
cat > analysis/success-rate.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: namespace
    - name: pod-template-hash
  metrics:
    - name: success-rate
      initialDelay: 30s          # new pods need a few scrapes before rate() means anything
      interval: 30s
      count: 4                   # ~2 minutes of evidence
      failureLimit: 1            # tolerate one bad sample (noise), fail on the second
      # No data / NaN counts as failure: "no evidence of health" is not health.
      successCondition: len(result) > 0 && !isNaN(result[0]) && result[0] >= 0.95
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(http_requests_total{
                  namespace="{{args.namespace}}",
                  rollouts_pod_template_hash="{{args.pod-template-hash}}",
                  status=~"2.."}[1m]))
            /
            sum(rate(http_requests_total{
                  namespace="{{args.namespace}}",
                  rollouts_pod_template_hash="{{args.pod-template-hash}}"}[1m]))
EOF
```

### success-rate-continuous (background watchdog)

```bash
cat > analysis/success-rate-continuous.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: success-rate-continuous
spec:
  args:
    - name: namespace
    - name: pod-template-hash
  metrics:
    - name: success-rate-continuous
      initialDelay: 30s
      interval: 30s
      # no "count": runs for the whole rollout, stopped by the controller when it completes
      failureLimit: 1
      successCondition: len(result) > 0 && !isNaN(result[0]) && result[0] >= 0.95
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(http_requests_total{
                  namespace="{{args.namespace}}",
                  rollouts_pod_template_hash="{{args.pod-template-hash}}",
                  status=~"2.."}[1m]))
            /
            sum(rate(http_requests_total{
                  namespace="{{args.namespace}}",
                  rollouts_pod_template_hash="{{args.pod-template-hash}}"}[1m]))
EOF
```

### latency-p95 (finite gate with an inconclusive band)

```bash
cat > analysis/latency-p95.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: latency-p95
spec:
  args:
    - name: namespace
    - name: pod-template-hash
  metrics:
    - name: latency-p95
      initialDelay: 30s
      interval: 30s
      count: 4
      failureLimit: 1
      inconclusiveLimit: 1
      # p95 (seconds):  <= 0.3 good | > 0.6 bad | in between: Inconclusive (a human decides)
      successCondition: len(result) > 0 && !isNaN(result[0]) && result[0] <= 0.3
      failureCondition: len(result) == 0 || isNaN(result[0]) || result[0] > 0.6
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: |
            histogram_quantile(0.95,
              sum by (le) (rate(http_request_duration_seconds_bucket{
                  namespace="{{args.namespace}}",
                  rollouts_pod_template_hash="{{args.pod-template-hash}}",
                  path="root"}[1m])))
EOF
```

### smoke-test (Job provider)

```bash
cat > analysis/smoke-test.yaml <<'EOF'
# A Kubernetes Job is the measurement: exit 0 = Successful, non-zero = Failed.
# Use it for functional checks that metrics can't express (e2e, contract tests, DB migrations...).
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: smoke-test
spec:
  args:
    - name: service-url            # e.g. http://podinfo-preview.bluegreen-demo.svc.cluster.local
  metrics:
    - name: smoke-test
      provider:
        job:
          spec:
            backoffLimit: 0
            activeDeadlineSeconds: 120
            template:
              spec:
                restartPolicy: Never
                containers:
                  - name: smoke
                    image: curlimages/curl:8.17.0
                    command: ["/bin/sh", "-c"]
                    args:
                      - |
                        set -eu
                        URL="{{args.service-url}}"
                        echo "smoke testing $URL"
                        curl -sf --max-time 5 "$URL/version"; echo
                        fails=0
                        for i in $(seq 1 30); do
                          code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/")
                          [ "$code" = "200" ] || { fails=$((fails+1)); echo "request $i -> $code"; }
                        done
                        echo "failures: $fails/30"
                        [ "$fails" -eq 0 ]
EOF
```

### http-health (Web provider)

```bash
cat > analysis/http-health.yaml <<'EOF'
# The Web provider calls an HTTP endpoint and evaluates a JSON field.
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: http-health
spec:
  args:
    - name: service-url
  metrics:
    - name: http-health
      interval: 5s
      count: 10
      failureLimit: 0
      successCondition: result == "OK"
      provider:
        web:
          url: "{{args.service-url}}/healthz"    # podinfo returns {"status": "OK"}
          timeoutSeconds: 5
          jsonPath: "{$.status}"
EOF
```

## 7.2 Deliver the library through GitOps

```bash
cat > platform/analysis-library.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: analysis-library
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"     # after the Rollouts CRDs (-5), before apps (5)
spec:
  project: platform
  source:
    repoURL: https://github.com/YOUR_GH_USER/rollouts-gitops-lab.git
    targetRevision: main
    path: analysis
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts             # ignored: ClusterAnalysisTemplates are cluster-scoped
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    retry:
      limit: 5
      backoff: { duration: 10s, factor: 2, maxDuration: 2m }
EOF

./scripts/fix-placeholders.sh
git add . && git commit -m "analysis: cluster analysis template library" && git push
argocd app get root --refresh >/dev/null
```

```bash
kubectl get clusteranalysistemplates
# NAME                      AGE
# http-health               ...
# latency-p95               ...
# smoke-test                ...
# success-rate              ...
# success-rate-continuous   ...
```

## 7.3 Test templates in isolation (a sandbox AnalysisRun)

You can't "run" a template directly, but you **can** create an `AnalysisRun` by hand with the
same metric inline. It's the quickest feedback loop for PromQL and conditions. These runs are
sandbox objects, so creating them with kubectl is fine: Argo CD doesn't track them.

Get the current stable hash:

```bash
export STABLE_HASH=$(kubectl -n canary-demo get rollout podinfo -o jsonpath='{.status.stableRS}')
echo "$STABLE_HASH"
```

### Test 7.3a: Prometheus metric should pass

```bash
cat <<EOF | kubectl -n canary-demo create -f -
apiVersion: argoproj.io/v1alpha1
kind: AnalysisRun
metadata:
  generateName: sandbox-success-rate-
spec:
  args:
    - name: namespace
      value: canary-demo
    - name: pod-template-hash
      value: "$STABLE_HASH"
  metrics:
    - name: success-rate
      interval: 10s
      count: 3
      successCondition: len(result) > 0 && !isNaN(result[0]) && result[0] >= 0.95
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(http_requests_total{namespace="{{args.namespace}}",rollouts_pod_template_hash="{{args.pod-template-hash}}",status=~"2.."}[1m]))
            /
            sum(rate(http_requests_total{namespace="{{args.namespace}}",rollouts_pod_template_hash="{{args.pod-template-hash}}"}[1m]))
EOF

kubectl -n canary-demo get analysisrun -w        # Running -> Successful (~20s)
kubectl -n canary-demo get analysisrun -o yaml | grep -A6 'measurements:' | head -30
```

**Expected:** `Successful`. Each measurement's `value` looks like `[1]`.

### Test 7.3b: the same metric with a wrong hash, to learn the "no data" behaviour

Re-run the command above with `value: "doesnotexist"`.
**Expected:** `Failed`. The empty result fails `len(result) > 0`. If you had written only
`result[0] >= 0.95`, you'd get **Error** measurements instead. Try it and compare.

### Test 7.3c: the Job provider against the healthy service

```bash
cat <<'EOF' | kubectl -n canary-demo create -f -
apiVersion: argoproj.io/v1alpha1
kind: AnalysisRun
metadata:
  generateName: sandbox-smoke-
spec:
  metrics:
    - name: smoke-test
      provider:
        job:
          spec:
            backoffLimit: 0
            template:
              spec:
                restartPolicy: Never
                containers:
                  - name: smoke
                    image: curlimages/curl:8.17.0
                    command: ["/bin/sh", "-c", "curl -sf --max-time 5 http://podinfo/version"]
EOF
kubectl -n canary-demo get analysisrun,job -w
```

**Expected:** a Job is created, completes, and the run is `Successful`. Change the URL to
`http://podinfo/status/500` (podinfo returns the requested status code) and re-run.
**Expected:** `Failed`.

### Test 7.3d: dry-run mode

`dryRun` evaluates a metric **without acting on it**. A failure is recorded but doesn't abort
the rollout. This is how teams onboard a new metric safely. Lab 08 uses it in a Rollout:

```yaml
analysis:
  templates: [...]
  dryRun:
    - metricName: latency-p95     # regex allowed, ".*" = all metrics
```

Clean up the sandbox runs:

```bash
kubectl -n canary-demo get analysisrun -o name | grep sandbox | xargs -r kubectl -n canary-demo delete
```

## Exercises

1. Write a `error-count` metric with **only** a `failureCondition` (`result[0] > 5`) and no
   success condition. What status do measurements get when there are no errors? (Hint: when
   only a failureCondition is set, not-failed means successful.)
2. Change the success-rate query to SLO style, `status=~"5.."` errors only, and compare the
   values during a bad release in lab 08.
3. Turn `success-rate` into a namespaced `AnalysisTemplate` inside `apps/canary-demo/`. When
   would a team want its own template instead of the shared one?

## Checkpoint

- [ ] `argocd app get analysis-library` is Synced/Healthy and has 5 ClusterAnalysisTemplates
- [ ] Sandbox runs: success-rate **Successful**, wrong-hash **Failed**, Job smoke **Successful**
- [ ] You can explain Failed vs Inconclusive vs Error, and what each does to a rollout

Next: [Lab 08: Canary with automated analysis](08-canary-with-analysis.md)
