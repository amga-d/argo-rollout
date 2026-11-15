# Lab 03: Bootstrap Argo CD & the App-of-Apps

## Objectives

* Install Argo CD. This is the **only** component installed imperatively.
* Log in with the UI and the CLI.
* Create the **root Application** (app-of-apps). From then on the cluster pulls everything else from Git.
* Create AppProjects that separate platform components from team applications.

## Concepts

| Term | Meaning |
|------|---------|
| **Application** | "Render *this* path/chart at *this* revision and make namespace X look like it" |
| **AppProject** | Guard rails: which repos, destinations and resource kinds an Application may use |
| **App-of-apps** | An Application whose manifests are *other Applications*. Commit a new Application file and it gets created |
| **Sync** | Apply the rendered desired state |
| **Refresh** | Re-read Git and re-compare. Happens every `timeout.reconciliation` (we set 60s) |
| **Self-heal** | Re-sync automatically when the live state drifts from Git |
| **Prune** | Delete live resources that were removed from Git |

## 3.1 Argo CD Helm values (stored in Git)

```bash
cd "$LAB_REPO"
cat > bootstrap/argocd-values.yaml <<'EOF'
# Argo CD bootstrap values. Chart: argo/argo-cd 10.17.2
global:
  domain: argocd.lab.local

configs:
  # TLS stays ON (the chart default, server.insecure: false). argocd-server generates a
  # self-signed certificate and serves HTTPS and gRPC on port 443. Lab clients skip the
  # certificate check (--insecure on the CLI, "proceed" in the browser) because nothing
  # in the lab issues a trusted certificate. The connection is still encrypted.
  cm:
    # Pull-based: how often Argo CD polls Git (default 120s + jitter).
    # A laptop cluster can't receive GitHub webhooks, so polling is the only trigger.
    timeout.reconciliation: 60s
    timeout.reconciliation.jitter: 10s
    # Show the logs/exec buttons for Rollout pods in the UI
    exec.enabled: true

dex:
  enabled: false          # local admin user only
notifications:
  enabled: false          # keep the lab light; Argo Rollouts has its own notifications

controller:
  resources:
    requests: { cpu: 100m, memory: 256Mi }
repoServer:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
server:
  resources:
    requests: { cpu: 50m, memory: 64Mi }
EOF
git add bootstrap && git commit -m "bootstrap: argocd values" && git push
```

## 3.2 Install Argo CD (one-time, imperative)

```bash
# (cluster)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.17.2 \
  -f "$LAB_REPO/bootstrap/argocd-values.yaml" \
  --wait

kubectl -n argocd get pods
```

> **Chicken-and-egg:** something has to install the thing that installs everything. A
> one-time `helm install` is the common answer. Section 3.6 (optional) hands Argo CD over to
> itself so that even this lives in Git afterwards.

## 3.3 Log in

```bash
# Terminal A: keep this running. Service ports 80 and 443 both reach the same container
# port (8080), which serves HTTPS and gRPC; 443 just makes the intent obvious.
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Terminal B
export ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
echo "$ARGOCD_PWD"
argocd login localhost:8080 --username admin --password "$ARGOCD_PWD" --insecure
argocd cluster list
```

UI: <https://localhost:8080> (user `admin`). The browser warns about the self-signed
certificate; accept it once ("Advanced → Proceed").

> **`--insecure` vs `--plaintext`.** The CLI always speaks TLS unless told otherwise.
> `--insecure` keeps TLS and only skips verifying the certificate, which is what a self-signed
> lab cert needs. `--plaintext` drops TLS entirely and only works if the server was installed
> with `server.insecure: true`. That is how the two get mixed up: a plaintext CLI against a TLS
> server, or the reverse, fails with errors such as `transport: authentication handshake
> failed` or `EOF`.
>
> The login is saved in `~/.config/argocd/config` together with the "insecure" choice, so later
> `argocd app ...` commands need no extra flags. If the port-forward drops, restart it and
> re-run the same `argocd login`.
>
> **Already installed with `server.insecure: true`?** Remove that line from
> `bootstrap/argocd-values.yaml`, re-run the `helm upgrade --install` from 3.2, then
> `kubectl -n argocd rollout restart deploy/argocd-server` (the server reads this parameter
> only at start-up), and re-login as above.

## 3.4 AppProjects

```bash
cd "$LAB_REPO"
cat > platform/projects.yaml <<'EOF'
# Platform components: may install anything, from anywhere (Helm repos, OCI registries).
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"   # create projects before the apps that use them
spec:
  description: Cluster add-ons owned by the platform team
  sourceRepos: ['*']
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
---
# Team applications: only from our repo, only into *-demo namespaces, no cluster-scoped objects
# except the Namespace itself (needed for CreateNamespace=true).
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: apps
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  description: Application teams' workloads
  sourceRepos:
    - https://github.com/YOUR_GH_USER/rollouts-gitops-lab.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '*-demo'
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
EOF
```

## 3.5 The root Application (app-of-apps)

```bash
cat > bootstrap/root-app.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  # Deleting "root" cascades to everything it created. Handy for cleanup, dangerous in prod.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_GH_USER/rollouts-gitops-lab.git
    targetRevision: main
    path: platform
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff: { duration: 10s, factor: 2, maxDuration: 3m }
EOF

./scripts/fix-placeholders.sh
git add . && git commit -m "platform: projects + root app" && git push

# (cluster) the last imperative apply of the whole lab
kubectl apply -f bootstrap/root-app.yaml
```

Watch it converge:

```bash
argocd app get root
argocd proj list           # platform and apps should appear
```

### Private repository? (skip if public)

Create a fine-grained GitHub PAT with *Contents: read-only* on this repo, then:

```bash
# (cluster) credentials are never committed to Git
argocd repo add https://github.com/$GITHUB_USER/rollouts-gitops-lab.git \
  --username "$GITHUB_USER" --password "<PAT>"
```

In production you'd use a GitHub App, or Sealed Secrets / External Secrets to manage this secret declaratively.

## 3.6 (Optional) Let Argo CD manage itself

Use a **multi-source** Application: the chart comes from the Helm repo and the values file
from *your* Git repo, so editing `bootstrap/argocd-values.yaml` upgrades Argo CD.

```bash
cat > platform/argocd.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
spec:
  project: platform
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 10.17.2
      helm:
        releaseName: argocd            # MUST match the bootstrap release name
        valueFiles:
          - $values/bootstrap/argocd-values.yaml
    - repoURL: https://github.com/YOUR_GH_USER/rollouts-gitops-lab.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: false, selfHeal: true }   # never let Argo CD prune itself
    syncOptions: [ServerSideApply=true]
EOF
./scripts/fix-placeholders.sh
git add . && git commit -m "platform: argocd manages itself" && git push
```

**Test it:** change `timeout.reconciliation` to `90s` in `bootstrap/argocd-values.yaml`, then
push. Within about a minute, run
`kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'`. It should
print `90s`. Set it back to `60s` afterwards.

## 3.7 Observe pull-based reconciliation

1. Run `argocd app get root -o json | jq -r '.status.reconciledAt'` twice, about a minute apart.
   The timestamp moves even though nothing changed. That's the polling loop.
2. Push any change to `platform/` and time how long it takes to appear. You can force it with
   `argocd app get root --refresh` (a refresh, not a sync).

## Checkpoint

- [ ] `argocd app list` shows `root` as **Synced / Healthy**
- [ ] `kubectl -n argocd get appprojects` lists `default`, `platform` and `apps`
- [ ] You can explain the difference between *refresh* and *sync*

Next: [Lab 04: Platform services](04-platform-services.md)
