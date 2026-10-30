#!/usr/bin/env bash
# Builds the platform control plane on the Part 1 cluster:
#   Gitea (lab Git server) -> Argo CD -> Crossplane v2 -> root Argo CD apps; everything else comes from Git.
# Idempotent: safe to re-run. Run from the Mac with the 5 VMs up.
source "$(dirname "$0")/../ops/lib.sh"
P=$(cd "$(dirname "$0")" && pwd)
WORK=$P/.work

ARGOCD_VERSION=v3.5.6
CROSSPLANE_VERSION=2.4.3
GITEA_NODEPORT=30300

# Sensitive commands: run quietly so that passwords never reach the log
quiet() { local node=$1; shift; vmq "$node" "$*" 2>&1 | { grep -v LIMA_CIDATA || true; }; }

log "1. helm on cp1"
vm cp1 'command -v helm >/dev/null || (curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash >/dev/null 2>&1); helm version --short'

log "2. Gitea (lab Git server)"
limactl cp "$P/gitea/gitea.yaml" cp1:/tmp/gitea.yaml 2>&1 | { grep -v LIMA_CIDATA || true; }
kc 'apply -f /tmp/gitea.yaml'
kc '-n gitea rollout status deployment/gitea --timeout=300s'
if ! vmq cp1 'kubectl -n gitea get secret gitea-admin' >/dev/null 2>&1; then
  quiet cp1 "kubectl -n gitea create secret generic gitea-admin --from-literal=password=\$(openssl rand -hex 16)" >/dev/null
fi
PW=$(vmq cp1 "kubectl -n gitea get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d")
quiet cp1 "kubectl -n gitea exec deploy/gitea -- gitea admin user create --admin --username platform --password '$PW' --email platform@example.com --must-change-password=false" | tail -1 || true
W1=$(node_ip w1)
GITEA="http://$W1:$GITEA_NODEPORT"
for r in platform-config team-blue-app; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "platform:$PW" -X POST "$GITEA/api/v1/user/repos" \
    -H 'Content-Type: application/json' -d "{\"name\":\"$r\",\"default_branch\":\"main\",\"private\":false}")
  echo "create repo $r: HTTP $code (201 = created, 409 = already exists)"
done

log "3. Seed the Git repositories from platform/repos/"
mkdir -p "$WORK"
for r in platform-config team-blue-app; do
  rm -rf "${WORK:?}/$r"; cp -R "$P/repos/$r" "$WORK/$r"
  (cd "$WORK/$r" && git init -q -b main && git add -A \
    && git -c user.name=platform -c user.email=platform@example.com commit -q -m "Initial commit" \
    && git remote add origin "$GITEA/platform/$r.git" \
    && git push -q --force "http://platform:$PW@${GITEA#http://}/platform/$r.git" main)
  echo "pushed $r -> $GITEA/platform/$r.git"
done

log "4. Argo CD $ARGOCD_VERSION (full install: API server + web UI + CLI access; Dex and notifications scaled to 0 to save memory)"
kc 'create namespace argocd --dry-run=client -o yaml | kubectl apply -f -'
kc "apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml 2>&1 | tail -3"
kc "-n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0"
# plain HTTP behind the NodePort (lab); restart so the server reads the setting
kc "-n argocd patch configmap argocd-cmd-params-cm --type merge -p '{\"data\":{\"server.insecure\":\"true\"}}'"
kc '-n argocd rollout restart deployment/argocd-server'
limactl cp "$P/argocd/argocd-ui.yaml" cp1:/tmp/argocd-ui.yaml 2>&1 | { grep -v LIMA_CIDATA || true; }
kc 'apply -f /tmp/argocd-ui.yaml'
kc '-n argocd rollout status statefulset/argocd-application-controller --timeout=300s'
kc '-n argocd rollout status deployment/argocd-server --timeout=300s'
kc '-n argocd wait --for=condition=Available deployment --all --timeout=300s'
echo "Argo CD UI: http://$W1:30090   (user admin; password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

log "5. Crossplane $CROSSPLANE_VERSION"
vm cp1 "helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null && helm repo update >/dev/null && helm upgrade --install crossplane crossplane-stable/crossplane -n crossplane-system --create-namespace --version $CROSSPLANE_VERSION --wait --timeout 5m 2>&1 | tail -4"

log "6. Hand over to GitOps: two root Argo CD Applications pointing at the platform-config repository"
limactl cp "$P/argocd/root-apps.yaml" cp1:/tmp/root-apps.yaml 2>&1 | { grep -v LIMA_CIDATA || true; }
kc 'apply -f /tmp/root-apps.yaml'

log "7. Wait for the platform API to come up (functions installed, XRD established)"
for i in $(seq 1 60); do
  if vmq cp1 'kubectl get xrd teamenvironments.platform.kiratech.io -o jsonpath="{.status.conditions[?(@.type==\"Established\")].status}"' 2>/dev/null | grep -q True; then break; fi
  sleep 5
done
kc 'wait function.pkg.crossplane.io --all --for=condition=Healthy --timeout=900s'
kc 'wait xrd/teamenvironments.platform.kiratech.io --for=condition=Established --timeout=120s'
kc 'get applications.argoproj.io -n argocd'
kc 'get xrd,compositions,functions'
kc 'api-resources --api-group=platform.kiratech.io'
echo
echo "Platform is up. Lab Git server from the Mac: $GITEA (user: platform, password in secret gitea/gitea-admin)"
