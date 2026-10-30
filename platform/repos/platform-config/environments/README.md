# Team environments

One file per team, named `<teamName>.yaml`. Committing a file here creates the environment,
removing it deletes it (Argo CD app `team-environments` reconciles this directory).

```yaml
apiVersion: platform.kiratech.io/v1alpha1
kind: TeamEnvironment
metadata:
  name: blue            # must equal spec.teamName
spec:
  teamName: blue        # 2-20 chars, lowercase letters, digits, "-"; immutable
  size: S               # S | M | L
  repoURL: http://gitea-http.gitea.svc.cluster.local:3000/platform/team-blue-app.git
  # optional: path (default "deploy"), targetRevision (default "HEAD"), group (default "team-<teamName>-devs")
```
