#!/usr/bin/env bash

init() {

  SESSION="ar"

  tmux new-session -s "${SESSION}"

  tmux attatch "${SESSION}"
}

pf() {
  local SESSION
  SESSION="$(tmux display-message -p '#S' 2>/dev/null)"
  : "${SESSION:?there is no active session}"

  local -a CMD=(
    "kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
    "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
    "kubectl port-forward -n argocd svc/argocd-server 8080:443"
    "kubectl port-forward -n argo-rollouts svc/argo-rollouts-dashboard 3100:3100"
  )

  tmux new-window -t "$SESSION" -n PF "${CMD[0]}"
  tmux set-option -w -t "$SESSION:PF" remain-on-exit on # keep errors visible

  local i
  for i in 1 2 3; do
    tmux split-window -t "$SESSION:PF" "${CMD[$i]}"
    tmux select-layout -t "$SESSION:PF" tiled
  done
}
case "$1" in
pf)
  pf
  ;;
init)
  init
  ;;
*)
  echo "usage: $0 [init|pf]" >&2
  exit 1
  ;;
esac
