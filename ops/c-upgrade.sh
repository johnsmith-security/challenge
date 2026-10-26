#!/usr/bin/env bash
# (c) Rolling upgrade of the whole cluster by ONE minor version (v1.34 -> v1.35) with a probed workload.
source "$(dirname "$0")/lib.sh"
DIR=$(cd "$(dirname "$0")" && pwd)

OLD_MINOR=v1.34
NEW_MINOR=v1.35
TS=$(date +%Y%m%d-%H%M%S)
PLOG=$(mktemp)
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true' EXIT

# kubectl with retries: the API can blip for a few seconds while a control plane is restarted
kcr() { local i; for i in 1 2 3 4 5 6; do kc "$@" && return 0; echo "(retrying in 5s)"; sleep 5; done; return 1; }

APT="sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y -qq --allow-change-held-packages"
upgrade_kubeadm() { vm "$1" "sudo apt-mark unhold kubeadm >/dev/null && $APT kubeadm=$PKG >/dev/null && sudo apt-mark hold kubeadm >/dev/null && kubeadm version -o short"; }
upgrade_kubelet() { vm "$1" "sudo apt-mark unhold kubelet kubectl >/dev/null && $APT kubelet=$PKG kubectl=$PKG >/dev/null && sudo apt-mark hold kubelet kubectl >/dev/null && sudo systemctl daemon-reload && sudo systemctl restart kubelet && kubelet --version"; }
cp_images() { kcr "-n kube-system get pods -l tier=control-plane -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image --sort-by=.metadata.name"; }

log "0. Pre-flight: versions, fresh etcd backup, where controller-manager/scheduler connect"
kc 'get nodes -o wide'
kc 'version'
vm cp1 "sudo mkdir -p /var/backups && kubectl -n kube-system exec etcd-cp1 -- etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_TLS snapshot save /var/lib/etcd/pre-upgrade.db 2>&1 | tail -2 && sudo mv /var/lib/etcd/pre-upgrade.db /var/backups/etcd-pre-upgrade-$TS.db && ls -l /var/backups/etcd-pre-upgrade-$TS.db"
vm cp1 'sudo grep -H "server:" /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf'

log "1. Deploy the sample workload (2 replicas, PDB minAvailable=1, preStop sleep) and start probing it every second"
limactl cp "$DIR/upgrade-demo.yaml" cp1:/tmp/upgrade-demo.yaml 2>&1 | { grep -v LIMA_CIDATA || true; }
kc 'apply -f /tmp/upgrade-demo.yaml'
kc '-n upgrade-demo rollout status deployment/nginx-demo --timeout=180s'
kc '-n upgrade-demo get deploy,pdb,svc,pods -o wide'
W1_IP=$(node_ip w1); W2_IP=$(node_ip w2)
URLS=("http://$W1_IP:30080/" "http://$W2_IP:30080/" "https://$VIP:6443/healthz")
for u in "${URLS[@]}"; do
  "$DIR/probe.sh" "$PLOG" "$u" & PIDS+=($!)
done
sleep 5
echo "probe targets: ${URLS[*]}"
echo "first probe lines:"; head -6 "$PLOG"

log "2. Point apt at the v1.35 repository on every node and pick the target patch version"
for n in "${CPS[@]}" "${WORKERS[@]}"; do
  vm "$n" "sudo sed -i 's#/$OLD_MINOR/#/$NEW_MINOR/#' /etc/apt/sources.list.d/kubernetes.list && sudo apt-get update -qq 2>&1 | tail -2; grep -o 'stable:/v[0-9.]*' /etc/apt/sources.list.d/kubernetes.list"
done
PKG=$(vmq cp1 "apt-cache madison kubeadm | head -1 | cut -d'|' -f2 | tr -d ' '")
TARGET="v${PKG%-*}"
echo "target package: kubeadm=$PKG  ->  Kubernetes $TARGET"
vm cp1 'apt-cache madison kubeadm | head -3'

log "3. Control planes, one at a time (cp1 runs 'kubeadm upgrade apply', the others 'kubeadm upgrade node')"
first=yes
for n in "${CPS[@]}"; do
  log "3.$n upgrade $n"
  upgrade_kubeadm "$n"
  if [ "$first" = yes ]; then
    vm cp1 'sudo kubeadm upgrade plan 2>&1 | tail -40'
    vm cp1 "sudo kubeadm upgrade apply $TARGET -y 2>&1 | tail -25"
    first=no
  else
    vm "$n" 'sudo kubeadm upgrade node 2>&1 | tail -15'
  fi
  kcr "drain $n --ignore-daemonsets --delete-emptydir-data --timeout=300s"
  upgrade_kubelet "$n"
  kcr "uncordon $n"
  kcr "wait --for=condition=Ready node/$n --timeout=300s"
  kcr 'get nodes'
  cp_images
done

log "4. Workers, one at a time (kubeadm upgrade node -> drain -> kubelet/kubectl -> uncordon)"
for n in "${WORKERS[@]}"; do
  log "4.$n upgrade $n"
  upgrade_kubeadm "$n"
  vm "$n" 'sudo kubeadm upgrade node 2>&1 | tail -8'
  kcr "drain $n --ignore-daemonsets --delete-emptydir-data --timeout=300s"
  kcr '-n upgrade-demo get pods -o wide'
  upgrade_kubelet "$n"
  kcr "uncordon $n"
  kcr "wait --for=condition=Ready node/$n --timeout=300s"
  kcr "-n upgrade-demo rollout status deployment/nginx-demo --timeout=180s"
  kcr 'get nodes'
done

log "5. Result: cluster state"
kcr 'get nodes -o wide'
kcr 'version'
cp_images
kcr 'get tigerastatus'
kcr 'get pods -A --no-headers | grep -v -E "Running|Completed" || echo "all pods Running/Completed"'
kcr '-n upgrade-demo get deploy,pdb,pods -o wide'

log "6. Result: the probe log (HTTP 200 = answered; 000 = no answer within 1s)"
sleep 3
kill "${PIDS[@]}" 2>/dev/null || true
echo "probe window: $(head -1 "$PLOG" | cut -d' ' -f1) -> $(tail -1 "$PLOG" | cut -d' ' -f1)"
for u in "${URLS[@]}"; do
  total=$(grep -c " $u " "$PLOG" || true)
  bad=$(grep " $u " "$PLOG" | grep -vc ' 200$' || true)
  printf '%-45s probes=%-5s failed=%s\n' "$u" "$total" "$bad"
done
echo "failed probes (if any):"
grep -v ' 200$' "$PLOG" || echo "  none"
cp "$PLOG" "$DIR/logs/c-upgrade-probe.log"
