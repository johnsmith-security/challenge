#!/usr/bin/env bash
# (a) Failure tolerance: crash the control plane that holds the VIP and show the API keeps working.
source "$(dirname "$0")/lib.sh"

log "1. Baseline: nodes, etcd members, VIP holder"
kc 'get nodes -o wide'
etcdctl_on cp1 'endpoint health --cluster -w table'
VICTIM=$(vip_holder)
SURVIVOR=
for n in "${CPS[@]}"; do
  if [ "$n" != "$VICTIM" ] && [ -z "$SURVIVOR" ]; then SURVIVOR=$n; fi
done
echo "VIP $VIP is held by: $VICTIM  (worst case: we kill it). kubectl will be run from: $SURVIVOR"
export KNODE=$SURVIVOR

log "2. Crash $VICTIM (force-stop = power loss) and poll the API through the VIP every second"
date +'stopped at %H:%M:%S'
limactl stop -f "$VICTIM" 2>&1 | { grep -v LIMA_CIDATA || true; }
down=0
for i in $(seq 1 60); do
  code=$(curl -sk -m 1 "https://$VIP:6443/healthz" || true)
  printf '%s t+%02ds healthz=%s\n' "$(date +%H:%M:%S)" "$i" "${code:-no-answer}"
  [ "$code" = ok ] || down=$((down + 1))
  [ "$i" -ge 20 ] && break
  sleep 1
done
echo "Seconds without an answer on the VIP during failover: $down"
echo "VIP holder now: $(vip_holder)"

log "3. The API works with only 2 of 3 control planes: read, write, delete"
kc 'get nodes'
kc 'create namespace ha-test'
kc 'create configmap written-during-outage -n ha-test --from-literal=proof=quorum-2-of-3'
kc 'create deployment web -n ha-test --image=nginx --replicas=2'
kc 'get cm,deploy -n ha-test'
kc 'get --raw=/readyz?verbose | tail -4'

log "4. etcd: 2 of 3 members healthy = quorum"
etcdctl_on "$SURVIVOR" 'endpoint health --cluster -w table' || true
etcdctl_on "$SURVIVOR" 'member list -w table'

log "5. After the node-monitor grace period the dead node is NotReady"
sleep 50
kc 'get nodes'
kc 'delete namespace ha-test --wait=false'

log "6. Bring $VICTIM back and confirm full health"
limactl start "$VICTIM" 2>&1 | { grep -v LIMA_CIDATA | tail -2 || true; }
kc "wait --for=condition=Ready node/$VICTIM --timeout=300s"
sleep 15
kc 'get nodes'
etcdctl_on "$SURVIVOR" 'endpoint health --cluster -w table'
echo "VIP holder: $(vip_holder)"
wait_api 60
