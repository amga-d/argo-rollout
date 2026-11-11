# Lab 05: Workload, Load Generator & Per-ReplicaSet Metrics

## Objectives

* Add an **ApplicationSet** so that every folder under `apps/` automatically becomes an Argo CD
  Application with its own namespace.
* Deploy podinfo as a **Rollout**, not a Deployment, with a load generator.
* Scrape metrics with a **PodMonitor** that keeps the `rollouts-pod-template-hash` label, which
  lets you query *canary* and *stable* separately.
* Create `scripts/release.sh`, the "CI pipeline" for the rest of the lab.

## Concepts

* A **Rollout** is a drop-in replacement for a Deployment: same `selector` and `template`, plus a
  `strategy.canary` or `strategy.blueGreen` block with much richer behaviour.
* Every ReplicaSet created by a Rollout labels its pods with
  `rollouts-pod-template-hash=<hash>`. **This label is how analysis tells canary pods from stable
  pods.** It ends up in your metrics if your scrape config copies it over.
* **The first deployment of a Rollout skips all steps.** There's no "old version" to protect,
  so it goes straight to 100%. Steps only run on *updates*.

## 5.1 ApplicationSet: one folder = one app = one namespace

```bash
cd "$LAB_REPO"
cat > platform/demo-apps-appset.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: demo-apps
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/YOUR_GH_USER/rollouts-gitops-lab.git
        revision: main
        directories:
          - path: apps/*
        requeueAfterSeconds: 60      # how often to look for new folders
  template:
    metadata:
      name: '{{.path.basename}}'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: apps
      source:
        repoURL: https://github.com/YOUR_GH_USER/rollouts-gitops-lab.git
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 5
          backoff: { duration: 10s, factor: 2, maxDuration: 2m }
EOF
```

## 5.2 The canary-demo application

```bash
mkdir -p apps/canary-demo
```

### Rollout

```bash
cat > apps/canary-demo/rollout.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: podinfo
  labels:
    app: podinfo
spec:
  replicas: 5
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
              value: "release-1"
            - name: PODINFO_RANDOM_ERROR
              value: "false"
            - name: PODINFO_RANDOM_DELAY
              value: "false"
            # --- static config ---
            - name: PODINFO_PORT_METRICS        # metrics + /healthz on a separate port,
              value: "9797"                     # unaffected by injected errors
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
    canary:
      # No traffic router yet: weight is approximated by the ratio of pods behind ONE Service.
      steps:
        - setWeight: 20
        - pause: {}                  # indefinite: waits for a human "promote"
        - setWeight: 50
        - pause: { duration: 60s }
        - setWeight: 80
        - pause: { duration: 60s }
EOF
```

### Service, PodMonitor, load generator

```bash
cat > apps/canary-demo/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: podinfo
spec:
  selector:
    app: podinfo          # selects stable AND canary pods => replica-ratio traffic split
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

cat > apps/canary-demo/podmonitor.yaml <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: podinfo
spec:
  selector:
    matchLabels:
      app: podinfo
  podMetricsEndpoints:
    - port: http-metrics
      path: /metrics
      interval: 10s
      relabelings:
        # Keep the Argo Rollouts ReplicaSet hash as a metric label.
        # This is what lets analysis query "only the canary pods".
        - sourceLabels: [__meta_kubernetes_pod_label_rollouts_pod_template_hash]
          targetLabel: rollouts_pod_template_hash
EOF

cat > apps/canary-demo/loadgen.yaml <<'EOF'
# Simulated users: ~4 concurrent clients hitting the Service continuously.
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
              TARGET=http://podinfo.canary-demo.svc.cluster.local/
              worker() { while true; do curl -s -o /dev/null --max-time 5 "$TARGET"; sleep 0.2; done; }
              for i in 1 2 3 4; do worker & done
              wait
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { memory: 64Mi }
EOF
```

> No `kustomization.yaml` is needed: Argo CD applies every manifest in a plain directory. Add
> Kustomize later if you want overlays (dev/stage/prod).

## 5.3 The release script (simulated CI)

```bash
cat > scripts/release.sh <<'EOF'
#!/usr/bin/env bash
# Simulates the CD half of a CI pipeline: change desired state in Git, commit, push.
# Argo CD (pull-based) picks it up on its next poll; Argo Rollouts does the progressive part.
#
#   usage: scripts/release.sh <app> <image-tag> <message> [good|bad|slow]
#     good  normal release
#     bad   ~1/3 of requests fail (PODINFO_RANDOM_ERROR=true)
#     slow  every request takes 0.8-1.5s (PODINFO_RANDOM_DELAY=true)
#   (message: no "/" or quotes)
set -euo pipefail

usage() { sed -n '2,10p' "$0"; exit 1; }
[[ $# -ge 3 ]] || usage
APP=$1 TAG=$2 MSG=$3 MODE=${4:-good}

cd "$(git rev-parse --show-toplevel)"
FILE="apps/${APP}/rollout.yaml"
[[ -f $FILE ]] || { echo "no such file: $FILE" >&2; exit 1; }

case $MODE in
  good) ERR=false; DELAY=false ;;
  bad)  ERR=true;  DELAY=false ;;
  slow) ERR=false; DELAY=true  ;;
  *) usage ;;
esac

# set the "value:" line that follows "- name: <ENV>"
set_env() { sed -i -E "/- name: $1\$/{n;s/(value: ).*/\1\"$2\"/}" "$FILE"; }

sed -i -E "s#(image: ghcr\.io/stefanprodan/podinfo:)[^[:space:]]+#\1${TAG}#" "$FILE"
set_env PODINFO_UI_MESSAGE   "$MSG"
set_env PODINFO_RANDOM_ERROR "$ERR"
set_env PODINFO_RANDOM_DELAY "$DELAY"

git --no-pager diff --stat -- "$FILE"
if git diff --quiet -- "$FILE"; then echo "nothing changed"; exit 0; fi

git add "$FILE"
git commit -q -m "release(${APP}): podinfo ${TAG} \"${MSG}\" [${MODE}]"
git push -q
git --no-pager log -1 --oneline
echo "pushed. Argo CD will pick it up within ~60s (or: argocd app get ${APP} --refresh)"
EOF
chmod +x scripts/release.sh
```

A helper that **samples which version answers**, so you can see the traffic split with your
own eyes:

```bash
cat > scripts/sample.sh <<'EOF'
#!/usr/bin/env bash
# usage: scripts/sample.sh <namespace> [url] [count] [extra curl args...]
# Sends <count> requests from inside the cluster and histograms the "message" field.
set -euo pipefail
NS=$1; URL=${2:-http://podinfo}; N=${3:-100}; shift $(( $# < 3 ? $# : 3 ))
EXTRA="$*"
kubectl -n "$NS" run "sampler-$RANDOM" --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.17.0 --command -- sh -c "
    for i in \$(seq $N); do
      curl -s --max-time 5 $EXTRA $URL/ | grep -o '\"message\": *\"[^\"]*\"' || echo 'ERROR/non-200'
    done | sort | uniq -c"
EOF
chmod +x scripts/sample.sh
```

Commit everything:

```bash
./scripts/fix-placeholders.sh
git add . && git commit -m "apps: canary-demo + appset + release tooling" && git push
argocd app get root --refresh
```

## 5.4 Verify the deployment

```bash
watch -n5 'argocd app list'                     # canary-demo should appear, then Synced/Healthy
kubectl argo rollouts get rollout podinfo -n canary-demo
```

Expected: one revision, 5/5 pods, status **✔ Healthy**, no steps executed. That's the
first-deploy rule.

```bash
./scripts/sample.sh canary-demo                 # 100 x "message": "release-1"
```

## 5.5 Verify the metrics pipeline

Prometheus → **Status → Targets**: find `podMonitor/canary-demo/podinfo/0`, 5 targets UP.

Run these in the Prometheus UI (<http://localhost:9090/graph>):

```promql
# 1) Requests per second, per ReplicaSet hash
sum by (rollouts_pod_template_hash) (rate(http_requests_total{namespace="canary-demo"}[1m]))

# 2) Success ratio (2xx / all) per hash: should be 1
sum by (rollouts_pod_template_hash) (rate(http_requests_total{namespace="canary-demo",status=~"2.."}[1m]))
/
sum by (rollouts_pod_template_hash) (rate(http_requests_total{namespace="canary-demo"}[1m]))

# 3) p95 latency per hash, in seconds: should be a few milliseconds
histogram_quantile(0.95,
  sum by (le, rollouts_pod_template_hash) (
    rate(http_request_duration_seconds_bucket{namespace="canary-demo",path="root"}[1m])))
```

Match the hash with the ReplicaSet:

```bash
kubectl -n canary-demo get rs -L rollouts-pod-template-hash
kubectl -n canary-demo get rollout podinfo -o jsonpath='{.status.stableRS}{"\n"}'
```

> **Why count non-2xx as failure?** podinfo's error injector returns 400, 409 and 500.
> Real SLOs usually count only 5xx, because a 4xx is often the client's fault. Use
> `status=~"5.."` for real services.

### (Optional) Grafana panel

Grafana → Dashboards → New → Add visualization → Prometheus. Paste query 2 with legend
`{{rollouts_pod_template_hash}}`, then save it as "podinfo releases". Keep it open during
the later labs to watch canaries live.

## Checkpoint

- [ ] `argocd app list` shows `canary-demo` (created by the ApplicationSet, not by you)
- [ ] `kubectl argo rollouts get rollout podinfo -n canary-demo` is Healthy with 5 pods
- [ ] Prometheus query 1 returns **one** series with a `rollouts_pod_template_hash` label
- [ ] `scripts/release.sh` and `scripts/sample.sh` are committed

Next: [Lab 06: Canary basics](06-canary-basics.md)
