# Lab 10: Canary with Traffic Routing (Gateway API + Envoy Gateway)

## Objectives

* Install **Envoy Gateway** (a Gateway API implementation) through Argo CD from an **OCI** Helm registry.
* Enable the **Argo Rollouts Gateway API plugin** declaratively.
* Run a canary where traffic weight is **exact** (5% means 5% of requests, whatever the pod
  count) and QA testers reach the canary with a **header** before any user does.
* Teach Argo CD to **ignore** the fields that Argo Rollouts changes at runtime (HTTPRoute weights
  and injected header rules). This is the classic GitOps + progressive-delivery conflict.

## Why traffic routing?

| | Replica-ratio canary (labs 06–08) | Traffic-routed canary (this lab) |
|--|-------------------------------|-------------------------------|
| 5% traffic with 4 replicas | impossible (25% minimum) | ✔ |
| Canary pod count | coupled to weight | independent (`setCanaryScale`) |
| Header/cookie routing for QA | ✖ | ✔ (`setHeaderRoute`) |
| Instant traffic cut on abort | scales pods down | flips weight to 0 immediately |
| Needs | nothing | an ingress/mesh/gateway + a plugin or a built-in integration |

```
loadgen ─▶ Envoy (Gateway "lab-gateway") ─▶ HTTPRoute podinfo
                                              ├─ weight 95 ─▶ svc podinfo-stable ─▶ stable RS
                                              ├─ weight  5 ─▶ svc podinfo-canary ─▶ canary RS
                                              └─ rule "qa-header" (X-Canary: true) ─▶ podinfo-canary
     Argo Rollouts + gatewayAPI plugin edit the weights and the header rule at runtime
```

## 10.1 Envoy Gateway via Argo CD (OCI chart)

Argo CD needs a repository entry marking the registry as an OCI Helm repo. It contains no
credentials (public registry), so it's fine to keep in Git:

```bash
cd "$LAB_REPO"
cat > platform/repo-envoyproxy-oci.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-envoyproxy-oci
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
stringData:
  name: envoyproxy
  type: helm
  url: docker.io/envoyproxy
  enableOCI: "true"
EOF

cat > platform/envoy-gateway.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: envoy-gateway
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: docker.io/envoyproxy        # OCI registry (no oci:// prefix here)
    chart: gateway-helm
    targetRevision: v1.10.0
    helm:
      releaseName: eg                    # also installs the Gateway API CRDs (crds.enabled=true)
  destination:
    server: https://kubernetes.default.svc
    namespace: envoy-gateway-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 10
      backoff: { duration: 15s, factor: 2, maxDuration: 3m }
EOF
```

## 10.2 Shared Gateway (platform-owned)

```bash
rm -f infra/gateway/.gitkeep
cat > infra/gateway/gateway.yaml <<'EOF'
# EnvoyProxy: give the generated Envoy Service a fixed name so in-cluster clients can find it.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: lab-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        name: lab-gateway-envoy
        type: ClusterIP              # use port-forward; no LoadBalancer on minikube
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: lab-proxy
    namespace: envoy-gateway-system
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All                  # app teams attach HTTPRoutes from their own namespaces
EOF

cat > platform/gateway-config.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: platform
  source:
    repoURL: https://github.com/YOUR_GH_USER/rollouts-gitops-lab.git
    targetRevision: main
    path: infra/gateway
  destination:
    server: https://kubernetes.default.svc
    namespace: envoy-gateway-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - SkipDryRunOnMissingResource=true     # CRDs come from envoy-gateway
    retry:
      limit: 10
      backoff: { duration: 15s, factor: 2, maxDuration: 3m }
EOF
```

## 10.3 Enable the traffic-router plugin in Argo Rollouts

The plugin is a binary the controller downloads at startup, configured in the
`argo-rollouts-config` ConfigMap. The Helm chart renders that ConfigMap from values, and its
checksum annotation restarts the controller when it changes.

```bash
python3 - <<'EOF'
p='platform/argo-rollouts.yaml'
s=open(p).read()
old="          # trafficRouterPlugins: []   <- added in lab 10\n"
new="""          trafficRouterPlugins:
            - name: argoproj-labs/gatewayAPI
              # arm64 machines: ...-linux-arm64
              location: https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.17.0/gatewayapi-plugin-linux-amd64
"""
assert old in s, "marker not found - edit platform/argo-rollouts.yaml by hand"
open(p,'w').write(s.replace(old,new))
EOF
```

> RBAC: the chart's `providerRBAC.gatewayAPI` (default `true`) already lets the controller
> read and update `httproutes`, `grpcroutes`, `tcproutes` and so on.

## 10.4 Teach Argo CD to ignore runtime-managed fields

During a canary the plugin **rewrites** `backendRefs[].weight` and **adds** a `qa-header` rule
to the HTTPRoute. Git says `100/0` and has no such rule, so with `selfHeal: true` Argo CD would
undo the canary's traffic shift every few seconds.

Add this to the ApplicationSet template:

```bash
python3 - <<'EOF'
p='platform/demo-apps-appset.yaml'
s=open(p).read()
old="""      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions:
          - CreateNamespace=true
"""
new="""      # Argo Rollouts owns these fields at runtime (traffic weights, header routes)
      ignoreDifferences:
        - group: gateway.networking.k8s.io
          kind: HTTPRoute
          jqPathExpressions:
            - .spec.rules[].backendRefs[].weight
            - .spec.rules[] | select(.name == "qa-header")
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions:
          - CreateNamespace=true
          - RespectIgnoreDifferences=true   # also skip those fields when syncing, not just in the diff
"""
assert old in s; open(p,'w').write(s.replace(old,new))
EOF
```

Commit the platform changes and let them converge:

```bash
./scripts/fix-placeholders.sh
git add . && git commit -m "platform: envoy gateway, gateway-api plugin, ignoreDifferences" && git push
argocd app get root --refresh >/dev/null
watch -n5 'argocd app list'
```

Verify:

```bash
kubectl -n envoy-gateway-system get pods,svc
kubectl get gatewayclass,gateway -A          # Gateway lab-gateway PROGRAMMED=True
kubectl -n argo-rollouts get cm argo-rollouts-config -o yaml | grep -A3 trafficRouterPlugins
kubectl -n argo-rollouts logs deploy/argo-rollouts | grep -i -E 'plugin|gatewayAPI' | tail
# expect lines about downloading argoproj-labs/gatewayAPI and finishing the download
```

## 10.5 The traffic-demo app

```bash
mkdir -p apps/traffic-demo
# reuse the canary-demo pod template, then replace the strategy
sed -e 's/value: "release-[^"]*"/value: "tr-1"/' \
    -e 's#podinfo:[0-9.]*#podinfo:6.15.0#' \
    -e 's/value: "true"/value: "false"/' \
    apps/canary-demo/rollout.yaml > apps/traffic-demo/rollout.yaml
sed -i 's/^  replicas: 5/  replicas: 4/' apps/traffic-demo/rollout.yaml
sed -i '/^  strategy:/,$d' apps/traffic-demo/rollout.yaml
cat >> apps/traffic-demo/rollout.yaml <<'EOF'
  strategy:
    canary:
      stableService: podinfo-stable
      canaryService: podinfo-canary
      abortScaleDownDelaySeconds: 30      # keep canary pods briefly after abort (debugging)
      trafficRouting:
        managedRoutes:
          - name: qa-header               # must match the setHeaderRoute name below
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoutes:
              - name: podinfo
                useHeaderRoutes: true
            namespace: traffic-demo
      analysis:                           # background watchdog once public traffic starts
        templates:
          - templateName: success-rate-continuous
            clusterScope: true
        startingStep: 4
        args:
          - name: namespace
            value: traffic-demo
          - name: pod-template-hash
            valueFrom:
              podTemplateHashValue: Latest
      steps:
        # 0: one canary pod, 0% of public traffic
        - setCanaryScale: { replicas: 1 }
        # 1: QA can reach the canary with "X-Canary: true"
        - setHeaderRoute:
            name: qa-header
            match:
              - headerName: X-Canary
                headerValue: { exact: "true" }
        # 2: automated functional check on the canary Service
        - analysis:
            templates:
              - templateName: smoke-test
                clusterScope: true
            args:
              - name: service-url
                value: http://podinfo-canary.traffic-demo.svc.cluster.local
        # 3: human QA sign-off
        - pause: {}
        # 4..: public traffic, exact percentages
        - setWeight: 5
        - setCanaryScale: { matchTrafficWeight: true }
        - pause: { duration: 60s }
        - setWeight: 25
        - pause: { duration: 60s }
        - analysis:
            templates:
              - templateName: latency-p95
                clusterScope: true
            args:
              - name: namespace
                value: traffic-demo
              - name: pod-template-hash
                valueFrom:
                  podTemplateHashValue: Latest
        - setWeight: 50
        - pause: { duration: 60s }
        - setWeight: 75
        - pause: { duration: 60s }
EOF
grep -n -E 'image:|value: "(tr-1|true|false)"|replicas:' apps/traffic-demo/rollout.yaml
```

```bash
cat > apps/traffic-demo/services.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: podinfo-stable
spec:
  selector: { app: podinfo }       # controller pins it to the stable hash
  ports: [{ name: http, port: 80, targetPort: http }]
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo-canary
spec:
  selector: { app: podinfo }       # controller pins it to the canary hash
  ports: [{ name: http, port: 80, targetPort: http }]
EOF

cat > apps/traffic-demo/httproute.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
spec:
  parentRefs:
    - name: lab-gateway
      namespace: envoy-gateway-system
  hostnames:
    - podinfo.lab.local
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:                 # weights are managed by Argo Rollouts at runtime
        - name: podinfo-stable
          port: 80
          weight: 100
        - name: podinfo-canary
          port: 80
          weight: 0
EOF

sed 's/canary-demo/traffic-demo/g' apps/canary-demo/podmonitor.yaml > apps/traffic-demo/podmonitor.yaml

cat > apps/traffic-demo/loadgen.yaml <<'EOF'
# Users arrive through the Gateway, like real ingress traffic.
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
              GW=http://lab-gateway-envoy.envoy-gateway-system.svc.cluster.local/
              worker() { while true; do curl -s -o /dev/null --max-time 5 -H 'Host: podinfo.lab.local' "$GW"; sleep 0.1; done; }
              for i in 1 2 3 4 5 6; do worker & done
              wait
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { memory: 64Mi }
EOF

git add apps/traffic-demo && git commit -m "apps: traffic-demo (gateway api canary)" && git push
argocd app get root --refresh >/dev/null
```

Verify:

```bash
kubectl -n traffic-demo get httproute podinfo -o jsonpath='{.status.parents[0].conditions[*].type}{"\n"}'  # Accepted ResolvedRefs
export GW=http://lab-gateway-envoy.envoy-gateway-system.svc.cluster.local
./scripts/sample.sh traffic-demo $GW 50 -H Host:podinfo.lab.local          # 50 x "tr-1"
kubectl argo rollouts get rollout podinfo -n traffic-demo --watch          # Terminal 1
```

---

## Test 10.1: Header-based QA, then exact weights

```bash
./scripts/release.sh traffic-demo 6.16.0 "tr-2" good
```

**Expected, phase 1 (dark launch):**

```bash
# public: 100% old
./scripts/sample.sh traffic-demo $GW 40 -H Host:podinfo.lab.local
# QA with header: 100% new
./scripts/sample.sh traffic-demo $GW 40 -H Host:podinfo.lab.local -H X-Canary:true
# see what the plugin did to the route
kubectl -n traffic-demo get httproute podinfo -o yaml | grep -E 'name:|weight|X-Canary' 
```

* There's 1 canary pod and the public weight is still 0.
* The smoke-test Job passes, then the rollout pauses at step 3.
* Argo CD for `traffic-demo` stays **Synced** even though the live HTTPRoute differs from Git.
  That's `ignoreDifferences` at work.

QA signs off:

```bash
kubectl argo rollouts promote podinfo -n traffic-demo
```

**Expected, phase 2:**

```bash
./scripts/sample.sh traffic-demo $GW 200 -H Host:podinfo.lab.local      # ≈ 190 / 10 at 5%
kubectl -n traffic-demo get httproute podinfo -o jsonpath='{.spec.rules[0].backendRefs}{"\n"}'
```

* `weight: 95 / 5` is exact, with only **1 canary pod out of 4**, which a replica-ratio
  canary can't do.
* Then 25% → latency gate → 50% → 75% → 100%. At the end the weights return to 100/0 pointing
  at the *new* stable (the stable Service selector moves), and the `qa-header` rule is removed.

---

## Test 10.2: Bad release, instant traffic cut

```bash
./scripts/release.sh traffic-demo 6.17.0 "tr-3-buggy" bad
```

**Expected:**

* The smoke test (step 2) fails at 0% public traffic, so users are never affected. Only QA, via
  the header, could have seen it.
* The rollout aborts: weights stay 100/0, the header rule is removed, and the canary pod lives
  30 s longer (`abortScaleDownDelaySeconds`) so you can debug it:

```bash
kubectl -n traffic-demo get pods -L rollouts-pod-template-hash
git revert --no-edit HEAD && git push
```

### Variant: a bug that only shows under real traffic

Make the smoke test pass by temporarily removing step 2 (the smoke-test analysis), commit, then
release `bad` again. The background `success-rate-continuous` should abort at **5%**. Afterwards,
restore step 2 and revert the release.

---

## Test 10.3: What happens without ignoreDifferences (optional drill)

1. In `platform/demo-apps-appset.yaml`, comment out the `ignoreDifferences` block and
   `RespectIgnoreDifferences=true`, then push.
2. Release `good` and promote past the QA pause.
3. Watch `kubectl -n traffic-demo get httproute podinfo -o jsonpath='{.spec.rules[0].backendRefs}' -w`.
   Weights flip between the rollout's value and Git's 100/0, and Argo CD shows the app
   **OutOfSync** with constant syncs.
4. Restore the block. **Lesson:** any controller that mutates objects Argo CD manages needs an
   explicit ownership split.

## Exercises

1. Add a second managed route, `beta-cookie`, that matches header `Cookie` with a regex on
   `beta=1` (`headerValue: { regex: ".*beta=1.*" }`), and remember to add it to
   `ignoreDifferences`.
2. Set `dynamicStableScale: true` under `canary:`. Watch the stable ReplicaSet scale *down* as
   the canary weight rises. When does that save money, and when is it risky?
3. Test with your browser: `kubectl -n envoy-gateway-system port-forward svc/lab-gateway-envoy 8888:80`,
   then add `127.0.0.1 podinfo.lab.local` to `/etc/hosts` and open <http://podinfo.lab.local:8888>.
   Use a header extension to send `X-Canary: true`.

## Checkpoint

- [ ] Envoy Gateway, gateway-config and the plugin were all installed **from Git**
- [ ] The QA header reached the canary while public weight was 0
- [ ] You saw a 95/5 split with 1 of 4 pods being canary
- [ ] A bad release aborted with no public exposure
- [ ] Argo CD stayed Synced during the canary (`ignoreDifferences`)

Next: [Lab 11: Experiments](11-experiments.md)
