# Lab 02: The GitOps Repository

## Objectives

* Create the Git repository that will be the **single source of truth** for the cluster.
* Understand the folder layout and who would own each folder in a real company.

## 2.1 Create the repository

Make it **public** to keep the lab simple: Argo CD can then pull without credentials.
(Section 3.5 covers private repos.)

```bash
# Option A: with the GitHub CLI
gh repo create rollouts-gitops-lab --public --clone --directory "$LAB_REPO"

# Option B: create "rollouts-gitops-lab" in the GitHub UI (empty, no README), then:
git clone https://github.com/$GITHUB_USER/rollouts-gitops-lab.git "$LAB_REPO"
```

```bash
cd "$LAB_REPO"
git checkout -b main 2>/dev/null || git checkout main
```

## 2.2 Target layout

You will fill this in gradually over the labs:

```
rollouts-gitops-lab/
├── bootstrap/                  # applied by hand ONCE (lab 03)
│   ├── argocd-values.yaml      #   Helm values for the Argo CD install
│   └── root-app.yaml           #   the app-of-apps
├── platform/                   # watched by the root app: Argo CD objects only
│   ├── projects.yaml           #   AppProjects (platform, apps)
│   ├── argo-rollouts.yaml      #   Application -> Helm chart
│   ├── kube-prometheus-stack.yaml
│   ├── analysis-library.yaml   #   Application -> analysis/
│   ├── demo-apps-appset.yaml   #   ApplicationSet -> one app per apps/* folder
│   ├── envoy-gateway.yaml      #   (lab 10)
│   └── gateway-config.yaml     #   (lab 10)
├── analysis/                   # ClusterAnalysisTemplates (shared "SRE library")
├── infra/
│   └── gateway/                # GatewayClass / Gateway (lab 10)
├── apps/                       # one folder = one Argo CD Application = one namespace
│   ├── canary-demo/
│   ├── bluegreen-demo/
│   └── traffic-demo/
└── scripts/
    └── release.sh              # "CI": edits desired state, commits, pushes
```

**Ownership in a real organization:**

| Folder | Owner | Change frequency |
|--------|-------|------------------|
| `bootstrap/`, `platform/`, `infra/` | Platform team | Rarely |
| `analysis/` | SRE (defines what "healthy" means) | Occasionally |
| `apps/*` | Application teams, mostly via CI tag bumps | Many times a day |

Many companies split these into separate repositories (a "platform repo" and an "app config
repo"). One repo keeps the lab simple, and the folders map one-to-one to a multi-repo setup.

> **Config repo vs source repo.** In real life the application *source code* lives in another
> repo. Its CI builds an image and then commits the new tag **here**. We simulate that with
> `scripts/release.sh` (lab 05) and, optionally, a GitHub Actions workflow (lab 12).

## 2.3 Create the skeleton

```bash
cd "$LAB_REPO"
mkdir -p bootstrap platform analysis infra/gateway apps scripts
touch analysis/.gitkeep infra/gateway/.gitkeep apps/.gitkeep

cat > README.md <<'EOF'
# rollouts-gitops-lab
Desired state for the progressive-delivery lab cluster. Argo CD pulls from `main`.
Do not `kubectl apply` by hand: change Git instead.
EOF

git add . && git commit -m "chore: repository skeleton" && git push -u origin main
```

## 2.4 Placeholder replacement helper

The YAML in the following labs uses `YOUR_GH_USER`. After you create files in a lab, run:

```bash
cd "$LAB_REPO"
grep -rl 'YOUR_GH_USER' --exclude-dir=.git . | xargs -r sed -i "s/YOUR_GH_USER/$GITHUB_USER/g"
grep -rn 'YOUR_GH_USER' --exclude-dir=.git . || echo "no placeholders left"
```

Save it as a script, since you'll run it often:

```bash
cat > scripts/fix-placeholders.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${GITHUB_USER:?export GITHUB_USER first}"
cd "$(git rev-parse --show-toplevel)"
PH="YOUR_GH""_USER"   # split so this script never matches (and rewrites) itself
grep -rl "$PH" --exclude-dir=.git . | xargs -r sed -i "s/$PH/$GITHUB_USER/g"
echo "placeholders replaced with $GITHUB_USER"
EOF
chmod +x scripts/fix-placeholders.sh
git add scripts && git commit -m "chore: placeholder helper" && git push
```

## 2.5 Branching model for the lab

* `main` is what the cluster runs. Argo CD tracks `main`.
* For real-world practice, you *can* open PRs for app changes and merge them. Argo CD only sees
  the result after the merge, which is how "PR = change request" works in GitOps shops.

## Checkpoint

- [ ] `git -C "$LAB_REPO" log --oneline` shows two commits
- [ ] The repo is visible at `https://github.com/$GITHUB_USER/rollouts-gitops-lab`
- [ ] You can explain why the CI system in this design never needs cluster credentials

Next: [Lab 03: Argo CD bootstrap](03-argocd-bootstrap.md)
