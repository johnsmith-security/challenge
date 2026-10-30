# 4. Structure of the Git repositories

Date: 2026-10-29

## Status
Accepted

## Context
Everything must be defined as code and stored in Git. A decision is required on how to split the code
into repositories and on which tool reconciles each part into the cluster, so that every object has exactly one owner:
> the platform team owns the cluster, the platform API and the team environments
> each business team owns only its application
> a team must not be able to raise its own quota or change its own RBAC

## Decision
It has been chosen to use three repositories, with one owner and one reconciler for each folder:

| Repository / folder | Content | Changed by | Reconciled by |
|---|---|---|---|
| `challenge` (this repo) | Lima template, cluster bootstrap, ops scripts, platform bootstrap, root Argo CD apps | Platform team | Nobody: run by hand once (day 0) |
| `platform-config/crossplane/` | Crossplane functions, RBAC, XRD (the API), Composition | Platform team | Argo CD, app `platform-api` |
| `platform-config/environments/` | One `TeamEnvironment` file per team | Platform engineer | Argo CD, app `team-environments`, then Crossplane creates the environment |
| `platform-config/cluster-maintenance/` | Calico CNI token refresh CronJob | Platform team | Argo CD, app `cluster-maintenance` |
| `team-<name>-app/deploy/` | The team's Deployments, Services, NetworkPolicies | The team | Argo CD, app `team-<name>` (created by Crossplane) |

Chain of ownership: Argo CD owns the `TeamEnvironment`, Crossplane owns everything composed from it
(namespace, quota, limits, RBAC, NetworkPolicies, AppProject, Application), and the team's Argo CD app owns the workload.

## Consequences
- Platform and team code are separated: a team commit can never change platform objects
- The per-team AppProject enforces the separation: only its own repo and namespace, no ResourceQuota, LimitRange or RBAC
- A new team environment is one file and one commit, with Git history as audit trail
- Argo CD, Crossplane, Gitea and Calico are installed by script, not from Git (bootstrap); they could later be moved under Argo CD
- `team-environments` uses `allowEmpty: true`: an empty commit would delete every environment, so `main` must be protected with reviews
