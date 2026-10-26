#!/usr/bin/env bash
# Helpers shared by the operations scripts (a-failover.sh, b-backup-restore.sh, c-upgrade.sh).
# Source this file; do not execute it.
set -euo pipefail

VIP=192.168.105.200
CPS=(cp1 cp2 cp3)
WORKERS=(w1 w2)
ETCD_TLS="--cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"

log() { printf '\n########## %s\n' "$*"; }

# Run a command line on a VM as the regular user, echoing it first.
# The script travels over stdin, so no quoting layers are involved.
# Usage: vm <node> '<command line>'
vm() {
  local node=$1; shift
  printf '\n$ [%s] %s\n' "$node" "$*"
  printf '%s\n' "$*" | limactl shell "$node" -- bash -s 2>&1 | { grep -v 'LIMA_CIDATA' || true; }
  return "${PIPESTATUS[1]}"
}

# Same as vm, but prints only the command output (to capture it in a variable).
vmq() {
  local node=$1; shift
  printf '%s\n' "$*" | limactl shell "$node" -- bash -s 2> >(grep -v 'LIMA_CIDATA' >&2)
}

# kubectl on a control plane (cp1 unless KNODE is set). Usage: kc 'get nodes'
kc() { vm "${KNODE:-cp1}" "kubectl $*"; }

# etcdctl inside the etcd static pod of <node>. Usage: etcdctl_on cp1 'member list -w table'
etcdctl_on() {
  local node=$1; shift
  vm "${KNODE:-cp1}" "kubectl -n kube-system exec etcd-$node -- etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_TLS $*"
}

# Name of the control plane that currently holds the VIP
vip_holder() {
  local n
  for n in "${CPS[@]}"; do
    if vmq "$n" "ip -4 -o addr show lima0 | grep -q ' $VIP/32' && echo yes" 2>/dev/null | grep -q yes; then
      echo "$n"; return 0
    fi
  done
  return 1
}

# lima0 address of a node (skips the /32 VIP)
node_ip() { vmq "$1" "ip -4 -o addr show lima0 scope global | grep -v '/32' | awk '{print \$4}' | cut -d/ -f1 | head -1"; }

# Wait (host side) until the API answers on the VIP; prints the elapsed time
wait_api() {
  local timeout=${1:-180} t=0
  until [ "$(curl -sk -m 2 "https://$VIP:6443/healthz" || true)" = ok ]; do
    t=$((t + 1)); [ "$t" -ge "$timeout" ] && { echo "API on VIP still down after ${timeout}s"; return 1; }
    sleep 1
  done
  echo "API on https://$VIP:6443 healthy after ~${t}s"
}
