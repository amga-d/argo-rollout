# Lab 04: Platform Services via GitOps (Argo Rollouts + Prometheus/Grafana)

## Objectives

* Install the Argo Rollouts controller and dashboard **by committing an Application to Git**.
* Install kube-prometheus-stack the same way, configured to pick up PodMonitors from any namespace.
* Learn the sync options that big charts need (`ServerSideApply`, `SkipDryRunOnMissingResource`).

## Concepts

* **Helm chart as an Argo CD source.** Argo CD runs `helm template` itself; there is no Helm
  release secret and `helm list` shows nothing. Values live in the Application (`valuesObject`),
  i.e. in Git.
* **Sync waves** order resources *within one sync*. Here the root app creates the projects at
  wave -10, then the add-ons at wave -5, and so on.
* **`ServerSideApply=true`**: CRDs such as Prometheus' are larger than the 256 KiB
  `last-applied-configuration` annotation allows with client-side apply. Server-side apply
  doesn't need that annotation.
* **`SkipDryRunOnMissingResource=true`**: lets a sync proceed when a resource's CRD doesn't
  exist *yet*, e.g. a `ServiceMonitor` before Prometheus is installed. The retry policy picks it
  up later.

## 4.1 Argo Rollouts Application

```bash
cd "$LAB_REPO"
cat > platform/argo-rollouts.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.43.12
    helm:
      releaseName: argo-rollouts
      valuesObject:
        controller:
          replicas: 1
          metrics:
            enabled: true
            serviceMonitor:
              enabled: true        # rendered once the Prometheus CRDs exist
          # trafficRouterPlugins: []   <- added in lab 10
        dashboard:
          enabled: true
        notifications:
          secret:
            create: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - SkipDryRunOnMissingResource=true
    retry:
      limit: 10
      backoff: { duration: 15s, factor: 2, maxDuration: 3m }
EOF
```

## 4.2 kube-prometheus-stack Application

```bash
cat > platform/kube-prometheus-stack.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 93.2.0
    helm:
      releaseName: kube-prometheus-stack   # => svc kube-prometheus-stack-prometheus:9090
      valuesObject:
        alertmanager:
          enabled: false
        grafana:
          adminPassword: admin               # lab only!
          defaultDashboardsTimezone: browser
        # These control-plane endpoints aren't reachable on minikube; disabling them
        # keeps the "Targets" page clean.
        kubeEtcd:              { enabled: false }
        kubeControllerManager: { enabled: false }
        kubeScheduler:         { enabled: false }
        kubeProxy:             { enabled: false }
        prometheus:
          prometheusSpec:
            scrapeInterval: 15s
            evaluationInterval: 15s
            retention: 2d
            # Select PodMonitors/ServiceMonitors in ALL namespaces, not only those
            # labelled release=kube-prometheus-stack. App teams own their monitors.
            podMonitorSelectorNilUsesHelmValues: false
            serviceMonitorSelectorNilUsesHelmValues: false
            ruleSelectorNilUsesHelmValues: false
            resources:
              requests: { cpu: 200m, memory: 512Mi }
              limits:   { memory: 1Gi }
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 10
      backoff: { duration: 15s, factor: 2, maxDuration: 3m }
EOF

git add platform && git commit -m "platform: argo-rollouts + kube-prometheus-stack" && git push
```

## 4.3 Watch the platform converge

```bash
argocd app get root --refresh          # don't wait for the 60s poll
watch -n5 'argocd app list'
```

Expect `argo-rollouts` and `kube-prometheus-stack` to go `OutOfSync → Syncing → Synced/Healthy`
within a few minutes. The Prometheus images are the slow part.

```bash
kubectl -n argo-rollouts get pods
kubectl -n monitoring get pods
kubectl get crd | grep -E 'argoproj.io|monitoring.coreos.com'
```

> **What if `argo-rollouts` synced before Prometheus existed?** Its `ServiceMonitor` was skipped
> during rendering, because the chart checks the cluster's API versions. After Prometheus is up,
> force a re-render with `argocd app get argo-rollouts --hard-refresh`.

## 4.4 Access the UIs

Run each in its own terminal, or background them:

```bash
kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100   # Rollouts dashboard
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80  # admin / admin
```

* Argo CD: <https://localhost:8080> (HTTPS, self-signed; the port-forward from lab 03)
* Rollouts dashboard: <http://localhost:3100/rollouts>
* Prometheus: <http://localhost:9090/targets>. The `argo-rollouts-metrics` target should be **UP**.
* Grafana: <http://localhost:3000>

> You can also run `kubectl argo rollouts dashboard` locally. It serves the same UI on :3100
> using your kubeconfig. The in-cluster dashboard is closer to what a team would share.

## 4.5 Prove that self-heal works (drift drill)

```bash
# (cluster) simulate a "quick fix in prod"
kubectl -n argo-rollouts scale deploy/argo-rollouts --replicas=0
sleep 20
kubectl -n argo-rollouts get deploy argo-rollouts
argocd app get argo-rollouts | grep -E 'Sync Status|Health Status'
```

Argo CD sees `replicas: 0` ≠ Git `replicas: 1` and puts it back. In a pull-based system,
changes made by hand don't stick, which is the property you want.

## Checkpoint

- [ ] `argocd app list`: `root`, `argo-rollouts` and `kube-prometheus-stack` are Synced/Healthy
- [ ] `kubectl get crd rollouts.argoproj.io analysistemplates.argoproj.io clusteranalysistemplates.argoproj.io`
- [ ] The Prometheus targets page shows Argo Rollouts controller metrics as UP
- [ ] The drift drill reverted automatically

Next: [Lab 05: Workload & observability](05-workload-and-observability.md)
