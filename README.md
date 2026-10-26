# Challenge Kiratech: highly available Kubernetes on Lima

A 5-node, highly available Kubernetes cluster (kubeadm, stacked etcd) running in Lima VMs on macOS, with a
kube-vip virtual IP in front of the API servers, Calico networking, and a documented, scripted and tested
procedure for **failure tolerance, backup/restore and a zero-downtime minor upgrade**.

| Role | VMs | Address | Notes |
|---|---|---|---|
| Control plane | `cp1` `cp2` `cp3` | 192.168.105.x (`lima0`) | 2 vCPU / 2.5 GiB, stacked etcd, kube-vip static pod |
| Workers | `w1` `w2` | 192.168.105.x (`lima0`) | 2 vCPU / 3 GiB |
| API endpoint (VIP) | n/a | `192.168.105.200:6443` | kube-vip, ARP mode, leader election |
| Pod network | n/a | `10.244.0.0/16` | Calico (tigera-operator), pinned to `lima0` |
| Kubernetes | n/a | built as **v1.34.12**, upgraded to **v1.35.9** | containerd 2.x, Ubuntu 24.04 arm64 |

## Repository layout

| Path | Purpose |
|---|---|
| [lima/k8s-node.yaml](lima/k8s-node.yaml) | Lima template: Ubuntu 24.04, containerd, kubeadm/kubelet/kubectl, `lima: shared` network |
| [bootstrap-cluster.sh](bootstrap-cluster.sh) | Builds the whole cluster on the 5 VMs (kube-vip, `kubeadm init`, Calico, all joins) |
| [ops/lib.sh](ops/lib.sh) | Shared helpers for the operations scripts |
| [ops/a-failover.sh](ops/a-failover.sh) | (a) Failure tolerance test |
| [ops/b-backup-restore.sh](ops/b-backup-restore.sh) | (b) etcd snapshot and restore test |
| [ops/c-upgrade.sh](ops/c-upgrade.sh), [ops/upgrade-demo.yaml](ops/upgrade-demo.yaml), [ops/probe.sh](ops/probe.sh) | (c) Rolling v1.34 → v1.35 upgrade with a probed workload |
| [ops/logs/](ops/logs) | Full, unedited output of every run documented below |

---

## 1. Prerequisites (host)

Lima's default `vzNAT` network **isolates the guests from each other** on macOS: the host can reach every VM,
but VMs cannot reach one another, so `kubeadm join` times out against the VIP. The VMs therefore use
`lima: shared` (socket_vmnet, `192.168.105.0/24`), which also contains the VIP. One-time host setup
(needs your password, so it is not scripted):

```sh
brew install socket_vmnet
# Lima requires socket_vmnet in a root-owned path
sudo mkdir -p /opt/socket_vmnet/bin
sudo cp /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /opt/socket_vmnet/bin/
sudo chown -R root:wheel /opt/socket_vmnet
limactl sudoers | sudo tee /etc/sudoers.d/lima
limactl sudoers --check          # must report that the file is up to date
```

## 2. Provision the VMs

```sh
limactl create --name=cp1 --cpus=2 --memory=2.5 --disk=20 --tty=false lima/k8s-node.yaml
limactl create --name=cp2 --cpus=2 --memory=2.5 --disk=20 --tty=false lima/k8s-node.yaml
limactl create --name=cp3 --cpus=2 --memory=2.5 --disk=20 --tty=false lima/k8s-node.yaml
limactl create --name=w1  --cpus=2 --memory=3   --disk=30 --tty=false lima/k8s-node.yaml
limactl create --name=w2  --cpus=2 --memory=3   --disk=30 --tty=false lima/k8s-node.yaml
for v in cp1 cp2 cp3 w1 w2; do limactl start $v; done
```

Check that the VMs see each other (every `lima0` address must answer from every VM):

```sh
limactl list
limactl shell cp2 -- ping -c1 -W2 192.168.105.3
```

> `lima/k8s-node.yaml` installs packages from the `K8S_MINOR="v1.34"` apt repository, so freshly created VMs
> are v1.34. Bump it if you want to start directly on a newer minor.

## 3. Build the cluster

```sh
./bootstrap-cluster.sh
```

The script is the automated form of the manual steps below. It:

1. sets `KUBELET_EXTRA_ARGS=--node-ip=<lima0 IP>` on every VM (all Lima VMs share the same `eth0` address, so kubelet would otherwise register the wrong InternalIP);
2. on `cp1`: generates the kube-vip static pod for the VIP, runs `kubeadm init --control-plane-endpoint $VIP:6443 --upload-certs`, installs Calico pinned to `lima0`;
3. joins `cp2` and `cp3` as control planes (one at a time, waiting for `Ready`) and adds kube-vip to each;
4. joins `w1` and `w2` as workers;
5. switches kube-vip on `cp1` from `super-admin.conf` back to `admin.conf` and copies the kubeconfig to the regular user on every control plane.

<details>
<summary>Manual steps (what the script does)</summary>

**On cp1: variables and kube-vip manifest**

```sh
export VIP=192.168.105.200
export KVVERSION=v0.8.9          # check github.com/kube-vip/kube-vip/releases
NODE_IP=$(ip -4 -o addr show lima0 | awk '{print $4}' | cut -d/ -f1 | head -1)

sudo mkdir -p /etc/kubernetes/manifests
sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip \
  /kube-vip manifest pod --interface lima0 --address $VIP \
  --controlplane --arp --leaderElection \
  | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

Kubernetes 1.29+ only: during `kubeadm init`, kube-vip must use `super-admin.conf` (revert it once all control planes joined):

```sh
sudo sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml
```

**On cp1: initialise**

```sh
sudo kubeadm init \
  --control-plane-endpoint "$VIP:6443" \
  --apiserver-advertise-address "$NODE_IP" \
  --pod-network-cidr 10.244.0.0/16 \
  --upload-certs \
  --ignore-preflight-errors=DirAvailable--etc-kubernetes-manifests
```

**On cp1: Calico.** The default pod CIDR `192.168.0.0/16` overlaps the VM network (`192.168.105.0/24`), so it is changed to match `--pod-network-cidr`; the node address autodetection is pinned to `lima0` because every VM has the same `eth0` address.

```sh
CALICO=v3.30.0
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/tigera-operator.yaml
curl -O https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/custom-resources.yaml
sed -i 's#192.168.0.0/16#10.244.0.0/16#' custom-resources.yaml
sed -i '/calicoNetwork:/a\    nodeAddressAutodetectionV4:\n      interface: lima0' custom-resources.yaml
kubectl create -f custom-resources.yaml
```

**Join credentials** (token: 24 h, certificate key: 2 h; regenerate on cp1 when expired):

```sh
CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1)
JOIN=$(sudo kubeadm token create --print-join-command)
echo "$JOIN --control-plane --certificate-key $CERT_KEY"     # for cp2, cp3
echo "$JOIN"                                                   # for w1, w2
```

**cp2, then cp3** (wait for `Ready` in between), after setting `--node-ip` as in step 1 of the list above:

```sh
NODE_IP=$(ip -4 -o addr show lima0 | awk '{print $4}' | cut -d/ -f1 | head -1)
sudo kubeadm join 192.168.105.200:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane --certificate-key <certificate-key> \
  --apiserver-advertise-address "$NODE_IP"
```

Then generate the same kube-vip manifest on the joined node, **without** the `super-admin.conf` change.

**w1, w2:** `sudo kubeadm join 192.168.105.200:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>`

**Finally:** on cp1 `sudo sed -i 's#super-admin.conf#admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml`.

Never commit real tokens, CA hashes or certificate keys: the certificate key gives access to the cluster's secrets.

</details>

## 4. Using kubectl

On every control plane, as the regular user (the bootstrap script does this):

```sh
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl get nodes -o wide
```

Without that, kubectl falls back to `localhost:8080` and reports `connection refused`. Worker nodes have no
`admin.conf`, so use a control plane (or the Mac) for kubectl. From the Mac, copy that file out of cp1; its server
address is the VIP, which the Mac can reach:

```sh
limactl shell cp1 -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/lima-ha.conf && chmod 600 ~/.kube/lima-ha.conf
export KUBECONFIG=~/.kube/lima-ha.conf
```

Health check of the freshly built cluster:

```sh
kubectl get nodes -o wide                          # 3 control-plane + 2 workers, INTERNAL-IP 192.168.105.x
kubectl get pods -A                                # everything Running
curl -sk https://192.168.105.200:6443/healthz      # ok
kubectl -n kube-system exec etcd-cp1 -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health --cluster -w table
```

---

# 5. Operating the cluster safely

Each scenario is a script in [ops/](ops) that prints every command it runs followed by its output. The excerpts
below are copied from the logs in [ops/logs/](ops/logs) (full output there). Scripts must be run **in order a, b,
c**, from the Mac, with all five VMs running:

```sh
cd ops
./a-failover.sh       > logs/a-failover.log 2>&1        # ~3 min
./b-backup-restore.sh > logs/b-backup-restore.log 2>&1  # ~3 min, API down for about a minute
./c-upgrade.sh        > logs/c-upgrade.log 2>&1         # ~20 min, upgrades the cluster to the next minor
```

To rehearse the upgrade again you must rebuild the cluster first (VMs are on the new version afterwards).

## 5a. Failure tolerance: stop one control plane, the API keeps working

Script: [ops/a-failover.sh](ops/a-failover.sh), log: [ops/logs/a-failover.log](ops/logs/a-failover.log).

The script finds the control plane that **holds the VIP** (the worst case, as the endpoint must move), force-stops
that VM (a power-loss style crash), and polls `/healthz` through the VIP every second from the Mac.

```text
VIP 192.168.105.200 is held by: cp3  (worst case: we kill it). kubectl will be run from: cp1

$ limactl stop -f cp3
10:34:05 t+01s healthz=no-answer
10:34:07 t+02s healthz=no-answer
10:34:09 t+03s healthz=no-answer
10:34:10 t+04s healthz=ok            <- kube-vip on another node took over the VIP
...
Seconds without an answer on the VIP during failover: 3
VIP holder now: cp2
```

With two of three control planes alive, **reads and writes both work**:

```text
$ kubectl create namespace ha-test
namespace/ha-test created
$ kubectl create configmap written-during-outage -n ha-test --from-literal=proof=quorum-2-of-3
configmap/written-during-outage created
$ kubectl create deployment web -n ha-test --image=nginx --replicas=2
deployment.apps/web created
$ kubectl get --raw=/readyz?verbose | tail -1
readyz check passed
```

etcd reports the dead member but still has quorum (2 of 3), and after the node-monitor grace period (~40 s) the node
is marked `NotReady`:

```text
| https://192.168.105.3:2379 |   true |   4.028464ms |                           |
| https://192.168.105.6:2379 |   true |   5.249674ms |                           |
| https://192.168.105.5:2379 |  false | 5.004544302s | context deadline exceeded |

NAME   STATUS     ROLES           AGE   VERSION
cp1    Ready      control-plane   42m   v1.34.12
cp2    Ready      control-plane   41m   v1.34.12
cp3    NotReady   control-plane   40m   v1.34.12
w1     Ready      <none>          39m   v1.34.12
w2     Ready      <none>          39m   v1.34.12
```

After `limactl start cp3` the node returns to `Ready`, etcd shows 3/3 healthy endpoints, and the VIP answers
(see the end of the log).

### What happens if a second control plane is lost

etcd is a Raft cluster: a write is committed only when a **majority** (quorum = ⌊n/2⌋+1) of members acknowledge it.
With 3 members the quorum is 2, so the cluster tolerates exactly **one** failure. Losing a second control plane
leaves 1 of 3 members, which is below quorum:

- **etcd becomes unavailable for reads and writes.** The surviving member refuses to serve rather than risk diverging from the others (consistency over availability, no split brain). `endpoint health` fails and `kube-apiserver` `/readyz` turns red.
- **The API is effectively down:** `kubectl` hangs or times out and nothing can be created, changed, scaled or deleted.
- **Already-running workloads keep running.** kubelet, containerd, kube-proxy and Calico keep working from their local state, so Pods keep serving traffic. Nothing is managed any more, though: no scheduling, no self-healing of crashed or evicted Pods, no rescheduling off a failed worker, no HPA, no Service endpoint updates (so a Pod that dies stays in the endpoints), no new rollouts. controller-manager and scheduler lose their leader-election leases because they need the API.
- **The VIP is not reliable:** kube-vip's leader election uses a Lease in the API, so the VIP can disappear even though a control-plane VM is still up.
- **Recovery:** bring one of the two lost nodes back and quorum is restored automatically, with no data loss. If both are gone for good, restore from an etcd snapshot (section 5b) or, as a last resort, start the survivor as a new single-member cluster (`--force-new-cluster`) and add members again.

Practical consequence: a 3-member control plane tolerates one failure at a time, and it needs time to heal between
failures. For two simultaneous failures you would need 5 members (quorum 3).

## 5b. Backup and restore with etcd

Script: [ops/b-backup-restore.sh](ops/b-backup-restore.sh), log: [ops/logs/b-backup-restore.log](ops/logs/b-backup-restore.log).

**1. Create something worth protecting** (a namespace with a Deployment, Service, ConfigMap and Secret):

```text
$ kubectl create namespace backup-demo
$ kubectl -n backup-demo create deployment web --image=nginx --replicas=2
$ kubectl -n backup-demo create configmap app-config --from-literal=greeting=hello-from-before-the-backup
$ kubectl -n backup-demo create secret generic app-secret --from-literal=password=<demo value>
$ kubectl -n backup-demo expose deployment web --port=80
deployment "web" successfully rolled out
```

**2. Take and verify the snapshot** from the local etcd member. `etcdctl` runs inside the etcd static pod; `etcdutl`
(downloaded in the script, same version as the running etcd) inspects the file on the host:

```text
$ kubectl -n kube-system exec etcd-cp1 -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key snapshot save /var/lib/etcd/snapshot.db
{"level":"info", ... "msg":"saved","path":"/var/lib/etcd/snapshot.db"}
Snapshot saved at /var/lib/etcd/snapshot.db

$ etcdutl snapshot status /var/backups/etcd-20261026-103707.db -w table
+----------+----------+------------+------------+---------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE | VERSION |
+----------+----------+------------+------------+---------+
| ca5600d7 |    11617 |       1157 |      13 MB |   3.6.0 |
+----------+----------+------------+------------+---------+
```

**3. Simulate the disaster.** First a change *after* the snapshot (it must be lost by the restore), then the
accidental deletion:

```text
$ kubectl create configmap created-after-backup -n default --from-literal=note=i-will-not-survive-the-restore
$ kubectl delete namespace backup-demo --wait=true
namespace "backup-demo" deleted
$ kubectl get namespace
NAME               STATUS   AGE
calico-apiserver   Active   44m
calico-system      Active   44m
default            Active   44m
kube-node-lease    Active   44m
kube-public        Active   44m
kube-system        Active   44m
tigera-operator    Active   44m
$ kubectl get all -n backup-demo
No resources found in backup-demo namespace.
```

**4. Restore.** On a stacked-etcd HA cluster all members must be restored from the **same** snapshot while the
API servers and etcd are stopped everywhere, otherwise the members would hold diverging histories:

1. Copy the snapshot to every control plane.
2. On every control plane, stop `kube-apiserver` and `etcd` by moving their static-pod manifests out of `/etc/kubernetes/manifests`. Wait until ports 2379 and 6443 are closed. Running Pods are unaffected.
3. On every control plane, keep the old data directory and restore into a new one, with the same `--initial-cluster` and a fresh `--initial-cluster-token`:

   ```sh
   sudo mv /var/lib/etcd /var/lib/etcd.pre-restore-<timestamp>
   sudo etcdutl snapshot restore /tmp/etcd-snapshot.db \
     --name cp1 \
     --initial-cluster 'cp1=https://192.168.105.3:2380,cp2=https://192.168.105.6:2380,cp3=https://192.168.105.5:2380' \
     --initial-cluster-token etcd-restore-<timestamp> \
     --initial-advertise-peer-urls https://192.168.105.3:2380 \
     --data-dir /var/lib/etcd
   ```
   (`--name` and the peer URL change per node.)
4. Move the `etcd.yaml` manifests back on all nodes, wait a few seconds, then move `kube-apiserver.yaml` back.

**5. Verify.** The namespace and all of its resources are back (same object names and ClusterIP), the ConfigMap and
Secret contents are intact, and the object created after the snapshot is gone:

```text
API on https://192.168.105.200:6443 healthy after ~1s

$ kubectl get namespace backup-demo
NAME          STATUS   AGE
backup-demo   Active   59s

$ kubectl -n backup-demo rollout status deployment/web --timeout=240s
deployment "web" successfully rolled out

$ kubectl -n backup-demo get deploy,po,svc,cm,secret
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           59s
pod/web-64c966cf88-cjf9d   1/1     Running   0          59s
pod/web-64c966cf88-nntdr   1/1     Running   0          59s
service/web   ClusterIP   10.106.85.176   <none>        80/TCP    59s
configmap/app-config         1      59s
secret/app-secret   Opaque   1      59s

$ kubectl -n backup-demo get configmap app-config -o jsonpath='{.data.greeting}'
hello-from-before-the-backup

$ kubectl get configmap created-after-backup -n default
Error from server (NotFound): configmaps "created-after-backup" not found
-> NotFound, as expected: everything written after the snapshot is lost
```

The three etcd members are `started` and healthy (note that the member IDs are new: a restore creates a new
cluster identity), all nodes are `Ready` and all Pods `Running`. The old data directories remain on the nodes as
`/var/lib/etcd.pre-restore-<timestamp>` for rollback; delete them when no longer needed.

### Risks of restoring a snapshot on a production cluster

- **Data loss back to the snapshot time (your RPO).** Everything written since is gone: new objects (shown above), but also *deletions and updates are reverted*, so rotated Secrets, changed Deployments, scaled replicas and RBAC changes come back in their old form. Snapshot often, and know your RPO.
- **etcd no longer matches reality.** Objects can reappear for Pods, Nodes or volumes that no longer exist (the kubelets and controllers must reconcile them), and resources created outside etcd after the snapshot (cloud load balancers, disks, DNS) become orphans, or objects pointing to resources that were deleted. **Persistent volume contents are not in etcd** and are not restored; use CSI/volume snapshots or Velero for data.
- **Cluster-wide downtime of the control plane.** The API is unavailable for the whole procedure (about a minute here, more with large data or mistakes). Workloads keep running, but nothing is managed meanwhile.
- **Time moves backwards for clients.** The etcd revision (resourceVersion) goes back, so controllers or operators holding newer cached versions can misbehave until they resync or are restarted. Restart components and operators after a restore if needed.
- **Partial or inconsistent restores are dangerous.** Restoring one member, or different snapshots on different members, or leaving an API server running, corrupts or forks the cluster. All members must use the same snapshot and the same new `--initial-cluster-token`, and API servers must be stopped.
- **Certificates and tokens can be stale.** Expired bootstrap tokens, rotated certificates and ServiceAccount tokens from before the snapshot can differ from what is on disk in `/etc/kubernetes/pki`. Back that directory up too, together with the kubeadm config and the kube-vip manifest. A snapshot alone does not rebuild a lost control-plane node.
- **The snapshot is a secrets dump.** It contains every Secret in clear text unless encryption at rest is configured. Store it encrypted, off the cluster and with tight access; the script keeps its local copy in a temporary directory that is deleted at exit, never in the repository.
- **Versions must match.** Restore with the same etcd/Kubernetes version the snapshot came from (or its direct upgrade path).
- **An untested backup is not a backup.** Practise the restore regularly (like this script), automate snapshots, and keep several generations. Taking the snapshot from a healthy member while the cluster is up is safe; prefer restoring on a new or isolated control plane if you only need to inspect data.

## 5c. Upgrade by one minor version without interrupting a workload

Script: [ops/c-upgrade.sh](ops/c-upgrade.sh), log: [ops/logs/c-upgrade.log](ops/logs/c-upgrade.log), probe log:
[ops/logs/c-upgrade-probe.log](ops/logs/c-upgrade-probe.log). Cluster upgraded **v1.34.12 → v1.35.9** (kubeadm
refuses to skip minor versions).

### Sample workload and probe

[ops/upgrade-demo.yaml](ops/upgrade-demo.yaml) deploys `nginx` with **2 replicas** in namespace `upgrade-demo`, built to survive node drains:

- `PodDisruptionBudget minAvailable: 1`, so a drain can never take both replicas down at once;
- `RollingUpdate maxUnavailable: 0`, preferred pod anti-affinity (spread over `w1`/`w2`), a 1-second readiness probe;
- `preStop: sleep 10`: after an eviction the Pod keeps answering while kube-proxy removes the endpoint, so in-flight and new connections do not hit a dead Pod;
- a `NodePort` Service (30080).

[ops/probe.sh](ops/probe.sh) runs on the Mac during the **whole** upgrade and requests, once per second, the
NodePort on **`w1`** and on **`w2`** (these must answer HTTP 200 all the time) and, for information, the API
`/healthz` through the VIP.

### Order of operations

0. **Pre-flight:** cluster healthy, fresh etcd snapshot (`/var/backups/etcd-pre-upgrade-*.db`), release notes read, PDB and replicas of the workload checked.
1. **Switch the package repository** on every node (`pkgs.k8s.io/.../v1.34/...` → `v1.35`; Kubernetes repositories are per minor) and choose the target patch (`apt-cache madison kubeadm` → `1.35.9-1.1`).
2. **First control plane (cp1):** upgrade the `kubeadm` package only, `kubeadm upgrade plan`, then `kubeadm upgrade apply v1.35.9`. It rolls the static pods (etcd, kube-apiserver, controller-manager, scheduler) of this node, one at a time, and updates cluster-wide config and RBAC. Then `kubectl drain cp1`, upgrade `kubelet` and `kubectl`, `systemctl restart kubelet`, `kubectl uncordon cp1`, wait for `Ready`.
3. **Other control planes (cp2, then cp3), one at a time:** upgrade `kubeadm`, `kubeadm upgrade node`, drain, upgrade kubelet/kubectl, restart, uncordon. kubeadm upgrades the addons (CoreDNS, kube-proxy) only once the last control plane is done (`Skipping upgrade of addons because control plane instances [cp2 cp3] have not been upgraded`).
4. **Workers (w1, then w2), one at a time:** `kubeadm` package, `kubeadm upgrade node`, drain from a control plane, upgrade kubelet/kubectl, restart, uncordon, and wait until the workload is `2/2` again before touching the next worker.
5. **Verify:** versions of all nodes and control-plane images, no non-running Pods, Calico `tigerastatus`, probe results.

Why this order: control plane before workers because kubelets must never be newer than the API servers; one node at a
time so etcd keeps its 2-of-3 quorum and the cluster keeps spare capacity for evicted Pods; the first control plane
uses `upgrade apply` (cluster-wide steps), all others `upgrade node`; every node is drained so its Pods are moved
gracefully while the PodDisruptionBudget protects the workload.

### Version skew rules followed

From the [Kubernetes version skew policy](https://kubernetes.io/releases/version-skew-policy/):

| Component | Rule | During this upgrade |
|---|---|---|
| `kubeadm` | Can upgrade a cluster by one minor at a time, never skip; the kubeadm binary must be the target version | 1.35.9 `kubeadm` on a 1.34.12 cluster; installed first on each node |
| `kube-apiserver` (HA) | Newest and oldest instance within **one minor** of each other | 1.34 ↔ 1.35 mixed while rolling cp1 → cp3, so within the limit |
| `kube-controller-manager`, `kube-scheduler` | Not newer than the apiserver they talk to; may be 1 minor older | Both kubeconfigs point at the node's **own** apiserver (`server: https://192.168.105.3:6443` on cp1), which is upgraded together with them, so they are never newer than their API server |
| `kubelet` | Not newer than the apiserver; up to **3 minors older** | Workers stayed on 1.34 while the API servers were on 1.35 (one minor older, allowed), then were upgraded last |
| `kube-proxy` | Not newer than the apiserver; ≤ 3 minors older; ±3 minors vs the node's kubelet | Upgraded by kubeadm with the last control plane; old proxies on 1.34 stayed valid until then |
| `kubectl` | Within **one minor** (older or newer) of the apiserver | The kubectl on cp1 (1.34) kept working against mixed 1.34/1.35 API servers until it was upgraded |

One nuance: when API servers are mixed, the policy narrows the allowed kubelet versions to those not newer than
the *oldest* API server. kubeadm's documented flow, which was followed here, upgrades each control plane's own
kubelet right after its control plane, so there is a window of several minutes in which cp1's kubelet (1.35) may
reach a 1.34 API server through the VIP. The strictly compliant alternative is to run `kubeadm upgrade apply/node`
on all three control planes first and only then upgrade their kubelets; this showed no problems here either way.

### Results

Before and after (full control-plane images in the log; kubeadm also moved etcd 3.6.5 → 3.6.6 and CoreDNS 1.12.1 → 1.13.1):

```text
$ kubectl get nodes                                  $ kubectl get nodes
cp1  Ready  control-plane  v1.34.12                  cp1  Ready  control-plane  v1.35.9
cp2  Ready  control-plane  v1.34.12                  cp2  Ready  control-plane  v1.35.9
cp3  Ready  control-plane  v1.34.12                  cp3  Ready  control-plane  v1.35.9
w1   Ready  <none>         v1.34.12                  w1   Ready  <none>         v1.35.9
w2   Ready  <none>         v1.34.12                  w2   Ready  <none>         v1.35.9

$ kubectl version
Client Version: v1.35.9
Server Version: v1.35.9

$ kubectl -n kube-system get pods -l tier=control-plane ...
etcd-cp{1,2,3}                      registry.k8s.io/etcd:3.6.6-0
kube-apiserver-cp{1,2,3}            registry.k8s.io/kube-apiserver:v1.35.9
kube-controller-manager-cp{1,2,3}   registry.k8s.io/kube-controller-manager:v1.35.9
kube-scheduler-cp{1,2,3}            registry.k8s.io/kube-scheduler:v1.35.9

$ kubectl get tigerastatus          # Calico v3.30 on Kubernetes 1.35
apiserver / calico / goldmane / ippools / whisker   all AVAILABLE=True, DEGRADED=False
$ kubectl get pods -A | grep -v -E "Running|Completed"
all pods Running/Completed
```

Draining a worker moves the workload to the other one. The PDB held the second eviction back until the first replacement was `Ready`:

```text
$ kubectl drain w1 --ignore-daemonsets --delete-emptydir-data
evicting pod upgrade-demo/nginx-demo-65b8f48cc6-lzrwp
error when evicting pods/"calico-typha-..." (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/nginx-demo-65b8f48cc6-lzrwp evicted
node/w1 drained

$ kubectl -n upgrade-demo get pods -o wide
nginx-demo-65b8f48cc6-gf77c   1/1   Running   10.244.80.202   w2
nginx-demo-65b8f48cc6-p8rxd   1/1   Running   10.244.80.209   w2
```

**Probe result, about 16 minutes (10:39:39 → 10:56:11), one request per second:**

```text
http://192.168.105.2:30080/                   probes=826   failed=0     (nginx via w1)
http://192.168.105.4:30080/                   probes=826   failed=0     (nginx via w2)
https://192.168.105.200:6443/healthz          probes=816   failed=7     (API via VIP, informational)
```

**The workload saw zero failed requests during the upgrade of 3 control planes and 2 workers.**

The 7 failed API probes (10:47:33-38 and 10:51:38-42, one `500`, the rest no answer in 1 s) happened while a control
plane's `kube-apiserver` static pod was being restarted and the VIP was moving. That is expected during a
control-plane upgrade; a client retrying for a few seconds, like kubectl in the script, is not affected. Running
workloads never depend on the API server to serve traffic.

---

## 6. Troubleshooting and lessons learned

| Symptom | Cause / fix |
|---|---|
| `kubeadm join` fails with `couldn't validate the identity of the API Server ... Client.Timeout exceeded` | With `vzNAT` the VMs cannot reach each other or the VIP. Use `lima: shared` (section 1) and verify with the ping matrix |
| `socket_vmnet has to be installed` / `Sorry, try again` from sudo | `/opt/socket_vmnet/bin/socket_vmnet` must exist, be root-owned and not reached through symlinks (Homebrew path is a symlink) |
| `kubectl` on a node: `localhost:8080 refused` | The regular user has no `~/.kube/config` (section 4) |
| Nodes register the same InternalIP | Every Lima VM has `eth0` = 192.168.5.15. Set `--node-ip` to the `lima0` address (the bootstrap script does) and pin Calico autodetection to `lima0` |
| VIP does not appear after `kubeadm init` | On Kubernetes 1.29+ kube-vip needs `super-admin.conf` during init; switch back to `admin.conf` after all control planes have joined |
| `crictl: command not found` for etcd checks | Run `etcdctl` through `kubectl exec etcd-<node>`; no host tooling is needed |
| `nslookup kubernetes.default` returns NXDOMAIN in a `busybox` pod | Test artefact of the recent busybox `nslookup`; use `busybox:1.28` or the FQDN (`kubernetes.default.svc.cluster.local`) |
| Join token or certificate key expired | `kubeadm token create --print-join-command` and `kubeadm init phase upload-certs --upload-certs` on a control plane |
| Failed join | `sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d` on that VM; for a half-added control plane also `kubectl delete node` and remove the stale etcd member before retrying |
