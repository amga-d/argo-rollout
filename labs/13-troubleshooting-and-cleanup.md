# Lab 13: Troubleshooting, Cheat Sheet & Cleanup

## 13.1 Debug playbook

Work from the outside in: **Git → Argo CD → Rollout → AnalysisRun → metrics → pods**.

```bash
# Git: is the change actually on main?
git -C "$LAB_REPO" log origin/main --oneline -5

# Argo CD: did it see and apply it?
argocd app get <app> --refresh
argocd app diff <app>
argocd app history <app>
kubectl -n argocd logs deploy/argocd-repo-server | tail            # render errors
kubectl -n argocd logs statefulset/argocd-application-controller | grep <app> | tail

# Rollout: what is the controller doing?
kubectl argo rollouts get rollout podinfo -n <ns>
kubectl -n <ns> describe rollout podinfo | sed -n '/Events/,$p'
kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -i <ns> | tail -50

# AnalysisRun: why did it fail?
kubectl -n <ns> get analysisrun
kubectl -n <ns> get analysisrun <name> -o json | jq '.status.metricResults[] | {name, phase, message, measurements: [.measurements[] | {phase, value, message}]}'

# Metrics: does the query return what you expect?
#   paste the query from the template into Prometheus, with the args substituted by hand
```

## 13.2 Common problems

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `argocd login` fails: `authentication handshake failed`, `EOF`, or `x509: certificate signed by unknown authority` | CLI flags don't match the server's TLS mode (`--plaintext` against a TLS server, or no `--insecure` with the self-signed cert), or the port-forward died | Forward `svc/argocd-server 8080:443`, then `argocd login localhost:8080 --insecure` (no `--plaintext`). Behind a proxy that breaks gRPC, add `--grpc-web` |
| Browser jumps from `http://localhost:8080` to `https://` and shows a certificate warning | Expected: TLS is on and argocd-server redirects HTTP to HTTPS; the certificate is self-signed | Accept the warning once ("Advanced → Proceed") |
| App stays `OutOfSync`, never syncs | Automated sync is off, or the sync failed | `argocd app get <app>` for the error; `argocd app sync <app>` |
| `the server could not find the requested resource` / `no matches for kind Rollout` | CRDs not installed yet (ordering) | Wait for the retry; check `SkipDryRunOnMissingResource=true`; check that the `argo-rollouts` app is Healthy |
| kube-prometheus-stack sync fails: `metadata.annotations: Too long` | Client-side apply on huge CRDs | `ServerSideApply=true` |
| Changes in Git take minutes to appear | Polling interval + ApplicationSet requeue | `argocd app get <app> --refresh`; `timeout.reconciliation` |
| AnalysisRun **Error**, `consecutiveErrorLimit` exceeded | Prometheus address wrong or unreachable, or PromQL syntax error | `kubectl -n monitoring get svc`; run the query in the UI |
| AnalysisRun **Failed** right away on a good release | Empty result (no data yet): `len(result) > 0` fails | Increase `initialDelay`; check the PodMonitor target is UP; check the hash label exists |
| No `rollouts_pod_template_hash` label in metrics | PodMonitor relabeling missing, or Prometheus doesn't select the PodMonitor | `podMonitorSelectorNilUsesHelmValues: false`; check Status → Targets |
| Rollout stuck `Paused` | `pause: {}` (expected), or an Inconclusive analysis | `kubectl argo rollouts promote` / `abort` |
| Rollout `Degraded` and stays that way | It was aborted; Git still declares the rejected version | `git revert` (or `kubectl argo rollouts retry rollout`) |
| Argo CD shows HTTPRoute OutOfSync during canary, weights flip back | `ignoreDifferences` / `RespectIgnoreDifferences` missing | Lab 10, section 10.4 |
| `plugin argoproj-labs/gatewayAPI not configured` / weights not changing | Plugin not downloaded (no egress, wrong arch), or the controller hasn't restarted | Controller logs; `kubectl -n argo-rollouts rollout restart deploy/argo-rollouts` |
| HTTPRoute not `Accepted` | Gateway `allowedRoutes`, wrong `parentRefs` namespace, Gateway not Programmed | `kubectl describe httproute`, `kubectl describe gateway -n envoy-gateway-system` |
| Blue-green rollback after post-promotion failure doesn't restore the old version | Old RS already scaled down | Increase `scaleDownDelaySeconds` beyond the post-promotion analysis duration |
| Smoke-test Job never starts | Image pull or quota problem; Job pending | `kubectl -n <ns> get jobs,pods`; `describe` the job pod |
| `release.sh` push rejected | Remote has bot commits (lab 12) | `git pull --rebase` |

## 13.3 Cheat sheet

### Argo Rollouts CLI

```bash
kubectl argo rollouts list rollouts -A
kubectl argo rollouts get rollout podinfo -n NS --watch
kubectl argo rollouts promote podinfo -n NS            # next step / past a pause
kubectl argo rollouts promote podinfo -n NS --full     # skip all remaining steps
kubectl argo rollouts abort podinfo -n NS              # back to stable
kubectl argo rollouts retry rollout podinfo -n NS      # restart an aborted rollout
kubectl argo rollouts pause podinfo -n NS
kubectl argo rollouts restart podinfo -n NS            # restart pods (no new revision)
kubectl argo rollouts list experiments -n NS
kubectl argo rollouts dashboard                        # local UI on :3100
# avoid with GitOps (they change spec): set image, undo, edit
```

### Argo CD CLI

```bash
argocd app list
argocd app get APP --refresh | --hard-refresh
argocd app diff APP
argocd app sync APP
argocd app history APP
argocd app actions list APP --kind Rollout
argocd app actions run APP promote-full --kind Rollout --resource-name podinfo
```

### Rollout strategy quick reference

```yaml
spec:
  rollbackWindow: { revisions: 3 }
  progressDeadlineSeconds: 180
  progressDeadlineAbort: true
  strategy:
    canary:
      stableService: ...           # required with trafficRouting
      canaryService: ...
      maxSurge: "25%"
      maxUnavailable: 0
      abortScaleDownDelaySeconds: 30
      dynamicStableScale: false
      trafficRouting: { plugins: {...}, managedRoutes: [...] }
      analysis:                    # background
        templates: [{ templateName: x, clusterScope: true }]
        startingStep: 1
        args: [{ name: a, value: b }, { name: h, valueFrom: { podTemplateHashValue: Latest } }]
        dryRun: [{ metricName: ".*" }]
      steps:
        - setWeight: 20
        - pause: {}                  # or { duration: 60s }
        - analysis: { templates: [...], args: [...] }
        - setCanaryScale: { replicas: 1 | weight: 10 | matchTrafficWeight: true }
        - setHeaderRoute: { name: r, match: [{ headerName: X, headerValue: { exact: v } }] }
        - experiment: { duration: 3m, templates: [...], analyses: [...] }
    blueGreen:
      activeService: ...
      previewService: ...
      autoPromotionEnabled: true
      autoPromotionSeconds: 120
      previewReplicaCount: 1
      scaleDownDelaySeconds: 600
      prePromotionAnalysis:  { templates: [...], args: [...] }
      postPromotionAnalysis: { templates: [...], args: [...] }
```

### Useful PromQL

```promql
# success ratio per RS hash
sum by (rollouts_pod_template_hash)(rate(http_requests_total{namespace="NS",status=~"2.."}[1m]))
/ sum by (rollouts_pod_template_hash)(rate(http_requests_total{namespace="NS"}[1m]))

# p95 latency per RS hash
histogram_quantile(0.95, sum by (le, rollouts_pod_template_hash)(
  rate(http_request_duration_seconds_bucket{namespace="NS",path="root"}[1m])))

# Argo Rollouts controller: rollout phase info
rollout_info{namespace="NS"}
analysis_run_metric_phase{namespace="NS"}
```

## 13.4 Cleanup

Partial cleanup (keep the platform, remove one app): delete the folder in Git. The
ApplicationSet removes the Application, and its finalizer removes the namespace's resources.

```bash
cd "$LAB_REPO"
git rm -r apps/traffic-demo && git commit -m "remove traffic-demo" && git push
```

Full teardown:

```bash
# cascade delete everything Argo CD created (root has the resources finalizer)
kubectl -n argocd delete application root
# then the cluster itself
minikube delete -p rollouts-lab
```

Keep the GitHub repo. It's your notebook, and lab 12.6 showed it can rebuild everything.

## 13.5 Where to go next

* **Notifications**: Argo Rollouts notifications (Slack/webhook on `on-rollout-aborted`,
  `on-analysis-run-failed`).
* **Argo CD Rollouts UI extension**: shows the Rollout dashboard inside the Argo CD UI.
* **Service mesh traffic routing**: Istio or Linkerd (SMI/Gateway API) for east-west canaries.
* **Analysis providers**: Datadog, New Relic, CloudWatch, Kayenta, or your own via a metric plugin.
* **Chaos during a canary**: inject faults (Chaos Mesh / Litmus) into canary pods and check that
  analysis catches them. A good way to measure your gates' detection time.
* **Promotion pipelines**: Kargo, or Argo CD Image Updater + Kustomize overlays for multi-env flows.
