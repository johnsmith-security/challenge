#!/usr/bin/env bash
# Part 3 evidence: the self-service "team environment" API, end to end.
#   1 the API exists   2 invalid requests are rejected   3 create an environment by committing to Git
#   4 create another (size M) with kubectl, resize it   5 RBAC   6 workload under default-deny   7 delete removes everything
source "$(dirname "$0")/../ops/lib.sh"
P=$(cd "$(dirname "$0")" && pwd)
W1=$(node_ip w1)
FAILS=0
REPO_IN_CLUSTER=http://gitea-http.gitea.svc.cluster.local:3000/platform/team-blue-app.git

# Wait on cp1 until a command succeeds. Usage: wait_for <seconds> '<command>'
wait_for() {
  local t=$1; shift
  for _ in $(seq 1 $((t / 3))); do vmq cp1 "$*" >/dev/null 2>&1 && return 0; sleep 3; done
  echo "TIMEOUT waiting for: $*"; return 1
}
# Make Argo CD look at Git now instead of waiting for its 3 minute poll (production would use a webhook)
refresh() { vmq cp1 "kubectl -n argocd annotate application $1 argocd.argoproj.io/refresh=hard --overwrite" >/dev/null; }
apply() { vm cp1 "kubectl apply -f - <<'EOF'
$1
EOF"; }
# expected failure / expected success wrappers
rejected() { if "$@"; then echo "!! UNEXPECTED: accepted"; FAILS=$((FAILS + 1)); else echo "-> rejected, as expected"; fi; }
blocked()  { if "$@"; then echo "!! UNEXPECTED: connection succeeded"; FAILS=$((FAILS + 1)); else echo "-> BLOCKED, as expected"; fi; }
allowed()  { if "$@"; then echo "-> allowed, as expected"; else echo "!! UNEXPECTED: blocked"; FAILS=$((FAILS + 1)); fi; }
gitpush() { # run in the work clone, never print the password
  (cd "$P/.work/platform-config" && git -c user.name=platform-engineer -c user.email=platform@example.com "$@")
}
PW=$(vmq cp1 "kubectl -n gitea get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d")
GIT_URL="http://platform:$PW@$W1:30300/platform/platform-config.git"
push() { (cd "$P/.work/platform-config" && git push -q "$GIT_URL" main 2>&1 | sed 's#//[^@]*@#//***@#'); }

log "1. The platform API exists"
kc 'get applications.argoproj.io -n argocd'
kc 'get xrd,compositions,functions'
kc 'api-resources --api-group=platform.kiratech.io'
kc 'explain teamenvironment.spec --recursive | head -20'

log "2. Invalid requests are rejected by the API server (nothing is created)"
echo "--- unknown size (XL)"
rejected apply 'apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata: { name: bad }
spec: { teamName: bad, size: XL, repoURL: "http://git.example/bad.git" }' || true
echo "--- missing teamName"
rejected apply 'apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata: { name: nameless }
spec: { size: S, repoURL: "http://git.example/x.git" }' || true
echo "--- missing size"
rejected apply 'apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata: { name: nosize }
spec: { teamName: nosize, repoURL: "http://git.example/x.git" }' || true
echo "--- invalid team name (uppercase, underscore)"
rejected apply 'apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata: { name: bad }
spec: { teamName: Bad_Name, size: S, repoURL: "http://git.example/x.git" }' || true
echo "--- repoURL is not a URL"
rejected apply 'apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata: { name: badurl }
spec: { teamName: badurl, size: S, repoURL: "not-a-url" }' || true
echo "--- metadata.name differs from teamName"
rejected apply 'apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata: { name: one }
spec: { teamName: other, size: S, repoURL: "http://git.example/x.git" }' || true
kc 'get teamenvironments'

log "3. Create an environment by committing ONE file to Git (GitOps path): environments/blue.yaml"
cat >"$P/.work/platform-config/environments/blue.yaml" <<EOF
apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata:
  name: blue
spec:
  teamName: blue
  size: S
  repoURL: $REPO_IN_CLUSTER
EOF
cat "$P/.work/platform-config/environments/blue.yaml"
gitpush add environments/blue.yaml
gitpush commit -q -m "Add team environment: blue (size S)"
push
(cd "$P/.work/platform-config" && git --no-pager log --oneline -3)
refresh team-environments
wait_for 240 'kubectl get namespace team-blue && kubectl -n argocd get application team-blue' || FAILS=$((FAILS + 1))
refresh team-blue || true
kc 'get teamenvironments'
kc 'get namespace team-blue --show-labels'
kc '-n team-blue get resourcequota,limitrange,rolebinding,networkpolicy'
kc '-n team-blue describe resourcequota team-quota'
kc '-n argocd get appproject,application | grep -E "NAME|team-blue"'
wait_for 300 'kubectl -n team-blue wait --for=condition=Available deployment --all --timeout=5s' || FAILS=$((FAILS + 1))
kc '-n argocd get application team-blue'
kc '-n team-blue get deploy,pods,svc,networkpolicy'

log "4. Create a second environment with kubectl (size M), then resize it"
apply "apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata:
  name: green
spec:
  teamName: green
  size: M
  repoURL: $REPO_IN_CLUSTER"
wait_for 180 'kubectl get namespace team-green && kubectl -n team-green get resourcequota team-quota' || FAILS=$((FAILS + 1))
kc 'get teamenvironments'
echo "--- quota of S (blue) vs M (green)"
kc "get resourcequota -A -o 'custom-columns=NS:.metadata.namespace,REQ_CPU:.spec.hard.requests\\.cpu,REQ_MEM:.spec.hard.requests\\.memory,LIM_CPU:.spec.hard.limits\\.cpu,LIM_MEM:.spec.hard.limits\\.memory,PODS:.spec.hard.pods' | grep -E 'NS|team-'"
echo "--- resize green M -> L"
kc "patch teamenvironment green --type merge -p '{\"spec\":{\"size\":\"L\"}}'"
wait_for 120 "kubectl -n team-green get resourcequota team-quota -o jsonpath='{.spec.hard.pods}' | grep -q 40" || FAILS=$((FAILS + 1))
kc "-n team-green get resourcequota team-quota -o jsonpath='{.spec.hard}{\"\\n\"}'"
echo "--- teamName is immutable (changing it would delete the namespace)"
rejected kc "patch teamenvironment green --type merge -p '{\"spec\":{\"teamName\":\"yellow\"}}'" || true
kc 'get teamenvironments'

log "5. RBAC: the team group can work in its own namespace only, and cannot touch platform-owned objects"
kc 'get rolebinding team-edit -n team-blue -o wide'
echo "--- can group team-blue-devs create deployments in team-blue?"
allowed kc 'auth can-i create deployments -n team-blue --as=alice --as-group=team-blue-devs'
echo "--- ...in team-green?"
blocked kc 'auth can-i create deployments -n team-green --as=alice --as-group=team-blue-devs' || true
echo "--- ...change its own ResourceQuota / NetworkPolicy defaults? (quota: must be no)"
blocked kc 'auth can-i update resourcequotas -n team-blue --as=alice --as-group=team-blue-devs' || true
echo "--- ...read nodes (cluster scope)?"
blocked kc 'auth can-i list nodes --as=alice --as-group=team-blue-devs' || true

log "6. Workload under default-deny: only the flows the app needs are open"
kc '-n team-blue get networkpolicy'
vm cp1 'kubectl -n team-blue delete pod intruder client --ignore-not-found --wait=true; kubectl -n default delete pod xns --ignore-not-found --wait=true' || true
vm cp1 'kubectl -n team-blue run intruder --image=busybox:1.28 --restart=Never -- sleep 3600 && kubectl -n team-blue run client --image=busybox:1.28 --restart=Never --labels=access=api-client -- sleep 3600 && kubectl -n default run xns --image=busybox:1.28 --restart=Never -- sleep 3600 && kubectl -n team-blue wait --for=condition=Ready pod/intruder pod/client --timeout=180s && kubectl -n default wait --for=condition=Ready pod/xns --timeout=180s'
sleep 5
echo "--- allowed: DNS works (platform allow-dns policy)"
allowed kc '-n team-blue exec deploy/api -- nslookup db'
echo "--- allowed: api -> db:5432 (team policy api-egress-to-db + db-ingress-from-api)"
allowed kc '-n team-blue exec deploy/api -- nc -zv -w 3 db 5432'
echo "--- allowed: labelled client -> api:8080 (team policy api-ingress-from-clients)"
allowed kc '-n team-blue exec client -- wget -qO- -T 3 http://api:8080'
echo "--- blocked: unlabelled pod in the same namespace -> api:8080"
blocked kc '-n team-blue exec intruder -- wget -qO- -T 3 http://api:8080' || true
echo "--- blocked: unlabelled pod -> db:5432 (only api may talk to the database)"
blocked kc '-n team-blue exec intruder -- nc -zv -w 3 db 5432' || true
echo "--- blocked: pod from ANOTHER namespace -> api:8080"
blocked kc '-n default exec xns -- wget -qO- -T 3 http://api.team-blue.svc.cluster.local:8080' || true
echo "--- blocked: api -> the internet (no egress rule)"
blocked kc '-n team-blue exec deploy/api -- wget -qO- -T 3 http://1.1.1.1' || true
vm cp1 'kubectl -n team-blue delete pod intruder client --wait=false; kubectl -n default delete pod xns --wait=false' || true

log "7. Deleting the resource removes the environment: blue via Git (git rm), green via kubectl delete"
gitpush rm -q environments/blue.yaml
gitpush commit -q -m "Remove team environment: blue"
push
(cd "$P/.work/platform-config" && git --no-pager log --oneline -3)
refresh team-environments
kc 'delete teamenvironment green --wait=false'
wait_for 240 '! kubectl get namespace team-blue 2>/dev/null && ! kubectl get namespace team-green 2>/dev/null' || FAILS=$((FAILS + 1))
kc 'get teamenvironments'
kc 'get namespace'
echo "--- nothing left behind:"
vm cp1 'kubectl -n argocd get applications,appprojects; kubectl get clusterrolebindings,rolebindings -A 2>/dev/null | grep -E "team-(blue|green)" || echo "no team-blue/team-green RBAC left"' || true

echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: all Part 3 checks behaved as expected"; else echo "RESULT: $FAILS unexpected outcome(s)"; exit 1; fi
