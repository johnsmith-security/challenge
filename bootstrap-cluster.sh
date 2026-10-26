#!/usr/bin/env bash
# Bootstraps a 3 control-plane + 2 worker kubeadm cluster on existing Lima VMs
# (cp1 cp2 cp3 w1 w2, created from lima/k8s-node.yaml with `lima: shared`).
# Run from the host: ./bootstrap-cluster.sh
set -euo pipefail

VIP=192.168.105.200
KVVERSION=v0.8.9
CALICO=v3.30.0
POD_CIDR=10.244.0.0/16
CPS="cp1 cp2 cp3"
WORKERS="w1 w2"

# Run a script (stdin) as root inside a VM
rsh() { limactl shell "$1" -- sudo bash -s 2>&1 | grep -v 'LIMA_CIDATA' || true; }
# Same, but fail on error and return output
rsh_out() { limactl shell "$1" -- sudo bash -s 2> >(grep -v 'LIMA_CIDATA' >&2); }

log() { printf '\n=== %s\n' "$*"; }

kubevip_manifest() { # $1 = vm, $2 = kubeconfig file name
  rsh_out "$1" <<EOF
set -euo pipefail
mkdir -p /etc/kubernetes/manifests
ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION >/dev/null
ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip manifest pod \
  --interface lima0 --address $VIP --controlplane --arp --leaderElection \
  > /etc/kubernetes/manifests/kube-vip.yaml
sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/$2#' /etc/kubernetes/manifests/kube-vip.yaml
EOF
}

log "Setting kubelet --node-ip (lima0) on all VMs"
for vm in $CPS $WORKERS; do
  rsh_out "$vm" <<'EOF'
set -euo pipefail
ip=$(ip -4 -o addr show lima0 | awk '{print $4}' | cut -d/ -f1 | head -1)
echo "KUBELET_EXTRA_ARGS=--node-ip=$ip" > /etc/default/kubelet
echo "$(hostname): $ip"
EOF
done

log "cp1: kube-vip (super-admin.conf) + kubeadm init"
kubevip_manifest cp1 super-admin.conf
rsh_out cp1 <<EOF
set -euo pipefail
NODE_IP=\$(ip -4 -o addr show lima0 | awk '{print \$4}' | cut -d/ -f1 | head -1)
kubeadm init \
  --control-plane-endpoint "$VIP:6443" \
  --apiserver-advertise-address "\$NODE_IP" \
  --pod-network-cidr $POD_CIDR \
  --upload-certs \
  --ignore-preflight-errors=DirAvailable--etc-kubernetes-manifests
mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config
EOF

log "cp1: Calico"
rsh_out cp1 <<EOF
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/tigera-operator.yaml
curl -fsSLo /tmp/custom-resources.yaml https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/custom-resources.yaml
sed -i 's#192.168.0.0/16#$POD_CIDR#' /tmp/custom-resources.yaml
# All Lima VMs share the same eth0 address, so pin Calico to lima0
sed -i '/calicoNetwork:/a\    nodeAddressAutodetectionV4:\n      interface: lima0' /tmp/custom-resources.yaml
for i in \$(seq 1 30); do kubectl create -f /tmp/custom-resources.yaml && break || sleep 5; done
kubectl wait --for=condition=Ready node/cp1 --timeout=600s
EOF

log "Generating join credentials"
CERT_KEY=$(rsh_out cp1 <<'EOF' | tail -1
kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1
EOF
)
JOIN=$(rsh_out cp1 <<'EOF' | tail -1
kubeadm token create --print-join-command 2>/dev/null
EOF
)
echo "join: ${JOIN%%--token*}--token <hidden> ..."

for vm in cp2 cp3; do
  log "$vm: join as control plane"
  rsh_out "$vm" <<EOF
set -euo pipefail
NODE_IP=\$(ip -4 -o addr show lima0 | awk '{print \$4}' | cut -d/ -f1 | head -1)
$JOIN --control-plane --certificate-key $CERT_KEY --apiserver-advertise-address "\$NODE_IP"
EOF
  kubevip_manifest "$vm" admin.conf
  rsh_out cp1 <<EOF
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl wait --for=condition=Ready node/$vm --timeout=600s
EOF
done

for vm in $WORKERS; do
  log "$vm: join as worker"
  rsh_out "$vm" <<EOF
set -euo pipefail
$JOIN
EOF
done

log "cp1: switch kube-vip to admin.conf (all control planes joined)"
rsh_out cp1 <<'EOF'
sed -i 's#path: /etc/kubernetes/super-admin.conf#path: /etc/kubernetes/admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml
EOF

log "Setting up kubectl for the regular user on every control plane"
for vm in $CPS; do
  limactl shell "$vm" -- bash -c 'mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config && chmod 600 ~/.kube/config' 2> >(grep -v 'LIMA_CIDATA' >&2)
done

log "Result"
rsh_out cp1 <<'EOF'
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl get nodes -o wide
kubectl get pods -A
EOF
