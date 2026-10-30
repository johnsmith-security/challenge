#!/usr/bin/env bash
# (b) etcd backup and restore on a 3-member stacked-etcd (kubeadm) cluster.
source "$(dirname "$0")/lib.sh"

TS=$(date +%Y%m%d-%H%M%S)
SNAP=/var/backups/etcd-$TS.db            # on cp1
WORK=$(mktemp -d)                        # on the Mac; snapshots contain every Secret, so keep them out of the repo
trap 'rm -rf "$WORK"' EXIT

log "0. Tooling: etcdutl/etcdctl matching the running etcd version on every control plane"
ETCD_VER=$(vmq cp1 "kubectl -n kube-system exec etcd-cp1 -- etcd --version | awk '/etcd Version/{print \$3}'")
echo "running etcd version: $ETCD_VER"
for n in "${CPS[@]}"; do
  # retries: right after a reboot (e.g. a-failover.sh) the node's DNS can need a few seconds
  vm "$n" "curl -fsSL --retry 10 --retry-delay 3 --retry-all-errors https://github.com/etcd-io/etcd/releases/download/v$ETCD_VER/etcd-v$ETCD_VER-linux-arm64.tar.gz | sudo tar xz --strip-components=1 -C /usr/local/bin etcd-v$ETCD_VER-linux-arm64/etcdctl etcd-v$ETCD_VER-linux-arm64/etcdutl && etcdutl version | head -1"
done

log "1. Create a namespace with some resources"
kc 'create namespace backup-demo'
kc '-n backup-demo create deployment web --image=nginx --replicas=2'
kc '-n backup-demo create configmap app-config --from-literal=greeting=hello-from-before-the-backup'
kc '-n backup-demo create secret generic app-secret --from-literal=password=s3cr3t'
kc '-n backup-demo expose deployment web --port=80'
kc '-n backup-demo rollout status deployment/web --timeout=180s'
kc '-n backup-demo get deploy,po,svc,cm,secret'

log "2. Take the snapshot (etcdctl snapshot save, from the local member) and verify it"
vm cp1 "sudo mkdir -p /var/backups && kubectl -n kube-system exec etcd-cp1 -- etcdctl --endpoints=https://127.0.0.1:2379 $ETCD_TLS snapshot save /var/lib/etcd/snapshot.db"
vm cp1 "sudo mv /var/lib/etcd/snapshot.db $SNAP && sudo chown \$(id -u):\$(id -g) $SNAP && chmod 600 $SNAP && ls -l $SNAP"
vm cp1 "etcdutl snapshot status $SNAP -w table"

log "3. Make a change AFTER the snapshot (it must be lost by the restore) and then 'accidentally' delete the namespace"
kc 'create configmap created-after-backup -n default --from-literal=note=i-will-not-survive-the-restore'
kc 'delete namespace backup-demo --wait=true'
kc 'get namespace'
kc 'get all -n backup-demo'

log "4. Restore. Copy the snapshot to every control plane"
limactl cp "cp1:$SNAP" "$WORK/snapshot.db" 2>&1 | { grep -v LIMA_CIDATA || true; }
for n in "${CPS[@]}"; do limactl cp "$WORK/snapshot.db" "$n:/tmp/etcd-snapshot.db" 2>&1 | { grep -v LIMA_CIDATA || true; }; done

IPS=(); IC=""
for n in "${CPS[@]}"; do
  ip=$(node_ip "$n"); IPS+=("$ip"); IC="${IC:+$IC,}$n=https://$ip:2380"
done
echo "initial-cluster: $IC"

log "4a. Stop kube-apiserver and etcd on ALL control planes (move their static-pod manifests away)"
for n in "${CPS[@]}"; do
  vm "$n" 'sudo mkdir -p /etc/kubernetes/manifests-stopped && sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests-stopped/'
done
for n in "${CPS[@]}"; do
  vm "$n" 'for i in $(seq 1 60); do ss -tln | grep -qE ":(2379|6443) " || break; sleep 2; done; if ss -tln | grep -qE ":(2379|6443) "; then echo STILL-RUNNING; else echo "etcd and kube-apiserver are stopped"; fi'
done

log "4b. On every member: keep the old data dir, restore the snapshot into a new one"
i=0
for n in "${CPS[@]}"; do
  vm "$n" "sudo mv /var/lib/etcd /var/lib/etcd.pre-restore-$TS && sudo etcdutl snapshot restore /tmp/etcd-snapshot.db --name $n --initial-cluster '$IC' --initial-cluster-token etcd-restore-$TS --initial-advertise-peer-urls https://${IPS[$i]}:2380 --data-dir /var/lib/etcd 2>&1 | tail -4; sudo ls /var/lib/etcd/member"
  i=$((i + 1))
done

log "4c. Start etcd on all members, then kube-apiserver"
for n in "${CPS[@]}"; do vm "$n" 'sudo mv /etc/kubernetes/manifests-stopped/etcd.yaml /etc/kubernetes/manifests/'; done
sleep 20
for n in "${CPS[@]}"; do vm "$n" 'sudo mv /etc/kubernetes/manifests-stopped/kube-apiserver.yaml /etc/kubernetes/manifests/'; done
wait_api 300

log "5. Verify: the namespace and its resources are back, the post-snapshot change is gone"
kc 'get nodes'
kc 'get namespace backup-demo'
kc '-n backup-demo rollout status deployment/web --timeout=240s'
kc '-n backup-demo get deploy,po,svc,cm,secret'
kc "-n backup-demo get configmap app-config -o jsonpath='{.data.greeting}{\"\\n\"}'"
kc "-n backup-demo get secret app-secret -o jsonpath='{.data.password}' | base64 -d; echo"
kc 'get configmap created-after-backup -n default' || echo "-> NotFound, as expected: everything written after the snapshot is lost"

log "6. etcd and cluster health after the restore"
etcdctl_on cp1 'member list -w table'
etcdctl_on cp1 'endpoint health --cluster -w table'
kc 'get pods -A --no-headers | grep -v -E "Running|Completed" || echo "all pods Running"'

log "7. Clean up the demo namespace (old data dirs are kept on the nodes as /var/lib/etcd.pre-restore-$TS)"
kc 'delete namespace backup-demo --wait=false'
