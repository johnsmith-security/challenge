# Situation 1 On a cluster installed over a year ago:

```sh
$ kubectl get nodes
NAME STATUS ROLES AGE VERSION
cp-1 Ready control-plane 398d v1.33.4
cp-2 Ready control-plane 398d v1.33.4
cp-3 Ready control-plane 398d v1.33.4
worker-1 NotReady <none> 398d v1.33.4
worker-1$ journalctl -u kubelet | tail -1

... "Unable to authenticate the request" err="[x509: certificate has
expired or is not yet valid: current time 2026-10-12T09:14:02Z is after
2026-10-10T08:02:11Z]"
```

The cluster is older than 365 days, which is the time certificates have been renewed at least once.
It is likely that during certifical renewal on a worker node something was not correctly functioning at the time.
It might be a node down during the rotation window or NTP not synced.

# Situation 2. A colleague added a fourth control-plane node to test a procedure, then deleted its VM.
# Since then the team has noticed that the cluster “no longer tolerates the loss of acontrol-plane node”:

```sh
$ etcdctl member list -w table

+---------+---------+------+-------------------------+
|    ID   | STATUS  | NAME |      PEER ADDRESS       |
+---------+---------+------+-------------------------+
| 2a1c... | started | cp-1 | https://10.0.10.11:2380 |
| 7f3b... | started | cp-2 | https://10.0.10.12:2380 |
| 9e05... | started | cp-3 | https://10.0.10.13:2380 |
| c41d... | started | cp-4 | https://10.0.10.14:2380 |
+------------------+---------+------+----------------+
```

The added node won't increase high availability or fault tolerance because it only works with odd numbers (2+1,3+2)
In this case, the ETCD cluster nodes are unable to reach the Quorum for leader election iin case a node goes down.

# Situation 3. A new Deployment stays Pending:

```sh
$ kubectl describe pod web-6d4f9c7b8-kx2lp | tail -2
Warning FailedScheduling 0/4 nodes are available: 1 Insufficient memory,
3 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }.
```

A colleague proposes to remove the taint from the control-plane nodes. What do you answer?

We should not proceed blindly, ask owner of the application the reason for the taint and proceed accordingly given the possible resource constraints, it is likely that the tain stems from the controlplane so is unlikely we can remove it safely.

# Situation 4. A team has just received its environment from the self-service API and deployed its application. 
# The pods are Running, but the application logs show that it cannot connect to its database, which runs in the same namespace:

```sh
$ kubectl -n team-blue exec deploy/api -- nslookup db
;; connection timed out; no servers could be reached
| ID +------------------+---------+------+---------------------------+
| STATUS | NAME | PEER ADDRS | 2a1c... | started | cp-1 | https://10.0.10.11:2380 | 7f3b... | started | cp-2 | https://10.0.10.12:2380 | 9e05... | started | cp-3 | https://10.0.10.13:2380 | c41d... | started | cp-4 | https://10.0.10.14:2380 4
$ kubectl -n team-blue exec deploy/api -- nc -zv 10.96.41.7 5432
10.96.41.7 (10.96.41.7:5432): Connection timed out
```

The team asks you to “just delete the NetworkPolicy”. What do you answer, and what do
you change in the team environment template so that the next team does not hit the same
problem?

I would not delete the network policy, instead I would modify to allow the DNS to be resolved and the traffic to flow from the API to the database.