# 1. Topology of the Kubernetes cluster

Date: 2026-10-29

## Status
Accepted

## Context
Is required a topology for the cluster that is highly available, reproducible and upgradable,
that allows for :
> Failure Tolerance
> Backup and Restore
> Upgrades

## Decision
It has been chosen a classic Kubernetes test cluster with 3 Controlplane nodes and 2 Workers

## Consequences
- Workload is scheduled on worker nodes only by default.
- Stacked ETCD
- Calico CNI with basic support for Networkpolicies