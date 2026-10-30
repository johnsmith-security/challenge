# 1. Krateo or ArgoCD ?

Date: 2026-10-29

## Status
Accepted

## Context
Is required a decision regarding which tool to use, Krateo or ArgoCD + Crossplane

## Decision
We choose ArgoCD + Crossplane for simplicity and familiarity with the tools

## Consequences

- Invalid API Requests are discarded by default
- Possibility to provision Team Environments via Git

