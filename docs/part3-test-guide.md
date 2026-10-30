# Part 3 test guide: team environments (CLI and GUI)

Manual version of [platform/demo.sh](../platform/demo.sh) (output: [platform/logs/part3-demo.log](../platform/logs/part3-demo.log)).
Prerequisite: the platform is installed (README §6) and `kubectl` points at the cluster
(`export KUBECONFIG=~/.kube/lima-ha.conf`). In zsh (the macOS default shell), run `setopt interactive_comments`
before pasting: otherwise the trailing `# comments` below are passed to the commands as arguments.

| What | URL | Login |
|---|---|---|
| Argo CD UI | http://192.168.105.2:30090 | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Gitea (Git server) | http://192.168.105.2:30300 | `platform` / `kubectl -n gitea get secret gitea-admin -o jsonpath='{.data.password}' \| base64 -d` |

`192.168.105.2` is w1; any node IP works. Argo CD polls Git every 3 minutes: press **Refresh** on an app (or run
`kubectl -n argocd annotate application team-environments argocd.argoproj.io/refresh=hard --overwrite`) to skip the wait.

## 1. The API exists

```sh
kubectl api-resources --api-group=platform.kiratech.io   # teamenvironments (tenv)
kubectl explain teamenvironment.spec
```
GUI: Argo CD → `platform-api` shows the XRD, the Composition and the Functions, all Healthy.

## 2. Invalid requests are rejected

```sh
kubectl apply -f - <<'EOF'
apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata: { name: bad }
spec: { teamName: bad, size: XL, repoURL: "http://x/y.git" }
EOF
# -> spec.size: Unsupported value: "XL": supported values: "S", "M", "L"
```
Also rejected: a missing `teamName` or `size`, a `teamName` that doesn't match `^[a-z]([-a-z0-9]*[a-z0-9])?$` (2–20 chars),
a `repoURL` that isn't http(s), `metadata.name` ≠ `teamName`, and changing `teamName`. `kubectl get tenv` stays empty.

GUI: in Gitea, add `platform-config/environments/oops.yaml` with `size: XL` and commit. In Argo CD, `team-environments`
shows **Sync failed** with the same message. Delete the file again.

## 3. Create an environment with one file in Git

```sh
git clone http://192.168.105.2:30300/platform/platform-config.git && cd platform-config
cat > environments/blue.yaml <<'EOF'
apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata:
  name: blue
spec:
  teamName: blue
  size: S
  repoURL: http://gitea-http.gitea.svc.cluster.local:3000/platform/team-blue-app.git
EOF
git add environments/blue.yaml && git commit -m "Add team environment: blue" && git push origin main   # Gitea login above
```
(GUI alternative: create the same file in Gitea. Without Git: `kubectl apply -f environments/blue.yaml`.)

Check (about 1–2 minutes):
```sh
kubectl get tenv                                                 # blue  S  SYNCED=True READY=True
kubectl -n team-blue get resourcequota,limitrange,rolebinding,networkpolicy
kubectl -n team-blue get deploy,pods,svc                         # api + db from the team's repo
```
GUI: Argo CD shows a new app **`team-blue`** with the `api` and `db` Deployments and the NetworkPolicies.

Resize: change `size` in `blue.yaml` and push (a `kubectl patch` would be reverted by Argo CD self-heal).
Sizes: **S** 0.5 CPU / 512Mi requests, 10 pods · **M** 1 / 1Gi, 20 · **L** 2 / 2Gi, 40.

## 4. RBAC for the team's group

```sh
kubectl auth can-i create deployments -n team-blue  --as=alice --as-group=team-blue-devs   # yes
kubectl auth can-i create deployments -n default    --as=alice --as-group=team-blue-devs   # no
kubectl auth can-i update resourcequotas -n team-blue --as=alice --as-group=team-blue-devs # no
kubectl auth can-i list nodes --as=alice --as-group=team-blue-devs                         # no
```

## 5. Workload under default-deny

The platform adds `default-deny-all` + `allow-dns`; the team repo opens only client → `api:8080` and `api` → `db:5432`.

```sh
kubectl -n team-blue run client   --image=busybox:1.28 --restart=Never --labels=access=api-client -- sleep 3600
kubectl -n team-blue run intruder --image=busybox:1.28 --restart=Never -- sleep 3600
kubectl -n team-blue wait --for=condition=Ready pod/client pod/intruder --timeout=120s

kubectl -n team-blue exec deploy/api -- nslookup db                    # allowed (DNS)
kubectl -n team-blue exec deploy/api -- nc -zv -w 3 db 5432            # allowed
kubectl -n team-blue exec client -- wget -qO- -T 3 http://api:8080     # allowed: api-ok
kubectl -n team-blue exec intruder -- wget -qO- -T 3 http://api:8080   # blocked (timeout)
kubectl -n team-blue exec intruder -- nc -zv -w 3 db 5432              # blocked
kubectl -n team-blue exec deploy/api -- wget -qO- -T 3 http://1.1.1.1  # blocked (no internet egress)
kubectl -n team-blue delete pod client intruder
```

## 6. Delete removes everything

```sh
git rm environments/blue.yaml && git commit -m "Remove team environment: blue" && git push origin main
kubectl get tenv,ns | grep -E 'NAME|blue'      # gone within about a minute
kubectl -n argocd get applications,appprojects # no team-blue left
```
GUI: delete the file in Gitea. The `team-blue` app disappears from Argo CD.
(For an environment created with kubectl: `kubectl delete tenv <name>`.)
