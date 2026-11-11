# Lab 01: Prerequisites & Local Cluster

## Objectives

* Verify the CLI tooling.
* Create a **dedicated** minikube profile so the lab can't break any other cluster you have.
* Understand what each component will cost in resources.

## 1.1 Tooling

| Tool | Why | Check |
|------|-----|-------|
| `docker` | minikube driver | `docker version` |
| `minikube` | local Kubernetes | `minikube version` |
| `kubectl` | cluster CLI | `kubectl version --client` |
| `helm` | **one-time** Argo CD bootstrap | `helm version --short` |
| `argocd` | Argo CD CLI | `argocd version --client --short` |
| `kubectl-argo-rollouts` | Rollouts CLI (`kubectl argo rollouts ...`) | `kubectl argo rollouts version` |
| `git` + a GitHub account | the GitOps source of truth | `git --version` |
| `jq`, `curl` | inspecting JSON/metrics | `jq --version` |
| `gh` (optional) | create the repo from the CLI | `gh --version` |

Run everything at once:

```bash
for c in docker minikube kubectl helm argocd kubectl-argo-rollouts git jq curl; do
  printf '%-24s' "$c"; command -v "$c" >/dev/null && echo OK || echo MISSING
done
kubectl argo rollouts version
```

### Installing a missing tool (Linux amd64)

```bash
# Argo Rollouts kubectl plugin
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
install -m 0755 kubectl-argo-rollouts-linux-amd64 ~/.local/bin/kubectl-argo-rollouts

# Argo CD CLI
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
install -m 0755 argocd ~/.local/bin/argocd
```

## 1.2 Resource budget

| Component | Approx. memory |
|-----------|----------------|
| Kubernetes control plane | ~1.0 GiB |
| Argo CD (server, repo-server, controller, appset, redis) | ~0.8 GiB |
| kube-prometheus-stack (Prometheus, Grafana, operator, KSM, node-exporter) | ~1.2 GiB |
| Argo Rollouts + dashboard | ~0.1 GiB |
| Envoy Gateway + one Envoy proxy | ~0.3 GiB |
| Demo apps (3 namespaces × ~5 podinfo pods + load generators) | ~0.4 GiB |

**Plan for 6 GiB RAM and 4 CPUs.** 8 GiB is more comfortable if your machine has room.

## 1.3 Create the cluster

Use a separate profile so the lab doesn't interfere with your existing `minikube` profile:

```bash
minikube start -p rollouts-lab \
  --driver=docker \
  --cpus=4 --memory=6144 --disk-size=30g \
  --container-runtime=containerd

# (optional) if you prefer KVM like your other profile:
#   minikube start -p rollouts-lab --driver=kvm2 --cpus=4 --memory=6144 --disk-size=30g
```

Make it the active context and enable metrics-server (for `kubectl top`):

```bash
minikube profile rollouts-lab
kubectl config use-context rollouts-lab
minikube -p rollouts-lab addons enable metrics-server

kubectl get nodes -o wide
kubectl get pods -A
```

> **Why a single node?** Progressive delivery is about ReplicaSets, Services and metrics, not
> scheduling. One node keeps the lab light. Kubernetes behaves the same way on a 50-node cluster.

## 1.4 Lab working directories

```bash
# Where you keep these lab instructions
export LAB_DOCS=~/Desktop/projects/argo-rollout
# Where your GitOps repo will be cloned in lab 02
export LAB_REPO=~/Desktop/projects/rollouts-gitops-lab
export GITHUB_USER=<your-github-username>

# Persist for new shells (optional)
cat >> ~/.bashrc <<EOF
export LAB_DOCS=$LAB_DOCS
export LAB_REPO=$LAB_REPO
export GITHUB_USER=$GITHUB_USER
EOF
```

## 1.5 Concepts to have in mind before continuing

**Push-based CD:** the CI system holds cluster credentials and runs `kubectl apply` or
`helm upgrade`. The cluster's state is whatever the last pipeline did.

**Pull-based GitOps (this lab):** an agent **inside** the cluster (Argo CD) keeps comparing the
cluster with Git and converges it toward Git. CI only writes to Git. Consequences:

* CI never needs a kubeconfig. Your laptop cluster can't receive inbound connections from
  GitHub, yet it still deploys from GitHub, because it reaches **out**.
* Drift is detected and, with self-heal, reverted.
* Rollback means changing Git (`git revert`), and history doubles as an audit log.

**Where Argo Rollouts fits:** Argo CD decides *what* the desired state is ("podinfo should run
6.16.0"). Argo Rollouts decides *how* the cluster moves from the old version to the new one
(20% → analyse → 40% → ... or blue → green), and whether to give up and roll back.

## Checkpoint

- [ ] `kubectl config current-context` prints `rollouts-lab`
- [ ] `kubectl get nodes` shows one `Ready` node
- [ ] `kubectl top nodes` returns numbers (metrics-server works; this can take a minute)
- [ ] `kubectl argo rollouts version` works

Next: [Lab 02: GitOps repository](02-gitops-repository.md)
