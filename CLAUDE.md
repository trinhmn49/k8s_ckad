# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a **CKAD (Certified Kubernetes Application Developer) exam preparation** repository. It contains:

- **lesson1/** — Application Design and Build (Pods, multi-container patterns, Jobs/CronJobs, Labels/Annotations, ConfigMaps/Secrets)
- **lesson2/** — Application Deployment, Services and Networking (rolling updates/rollbacks, DNS-based service discovery)
- **weather-alert/** — A real 12-factor microservices project (Go, PostgreSQL, Redis, NATS) that lesson1/1.5 and lesson2's labs use as live subject matter — see [weather-alert/CLAUDE.md](weather-alert/CLAUDE.md)

Each lesson contains numbered labs (1.1, 1.2, 1.3, etc.) with YAML manifests and kubectl commands demonstrating specific CKAD exam domains.

## Lab File Format

Each lab file (e.g., `lab_1.1.yaml`) is structured as a standalone resource with:

1. **Header comments** — Lab title, duration estimate, CKAD domain, and learning objectives
2. **DETAILED EXPLANATION section** — Concepts and commands explained line-by-line
3. **STEP-BY-STEP sections** — Each step with numbered commands to run
4. **YAML manifests** — Example Kubernetes object definitions (reference shapes)
5. **VERIFICATION commands** — Non-editor methods to confirm successful completion (crucial for exam speed)
6. **EXAM TIPS** — Speed tactics and common pitfalls
7. **CLEANUP section** — How to remove created resources

The YAML in these files is **NOT meant to be applied with `kubectl apply -f`** — it's reference documentation. Labs typically use **imperative commands** (`kubectl run`, `kubectl create`, etc.) to demonstrate exam speed technique.

## Core CKAD Concepts & Command Patterns

### Pod Creation (Imperative)
```bash
kubectl run <name> --image=<image> \
  --labels="key=val,key2=val2" \
  --env="VAR=value" \
  --requests="cpu=100m,memory=128Mi" \
  --limits="cpu=500m,memory=256Mi" \
  --port=<port> \
  --dry-run=client -o yaml
```

### Labels & Selectors
- **Equality**: `-l env=prod`
- **Inequality**: `-l env!=prod`
- **Set membership**: `-l 'tier in (frontend,cache)'`
- **Existence**: `-l tier` (has key) or `-l '!tier'` (no key)
- **Bulk update**: `kubectl label pods -l selector key=value --overwrite`

### Annotations
- Informational metadata (not queryable like labels)
- `kubectl annotate pods <name> key="value" --overwrite`

### Job & CronJob
- One-off Job: `kubectl create job <name> --image=<image>`
- CronJob: Defined in YAML, uses cron schedule syntax
- Common flags: `--restart=Never` (Job), `--restart=OnFailure` (Job with retries)

## Working with Labs

### To Study a Lab:
1. **Read the header** — Understand the learning objective and CKAD domain
2. **Read DETAILED EXPLANATION** — Build conceptual understanding
3. **Follow STEP-BY-STEP** — Execute commands one at a time
4. **Run VERIFICATION commands** — Don't use an editor; learn jsonpath/kubectl introspection
5. **Review EXAM TIPS** — Internalize speed techniques

### To Practice Under Time Pressure:
- Hide the solution, attempt the lab from scratch
- Use `--dry-run=client -o yaml` to preview before creating
- Use jsonpath queries (`-o jsonpath='...'`) instead of opening a text editor
- Practice combining commands (`kubectl get pods -l selector -o name | ...`)

### Verification Without an Editor (Exam Speed)
```bash
# View object in YAML without opening vi/nano:
kubectl get <type> <name> -o yaml

# Extract specific fields with jsonpath:
kubectl get pod web-server -o jsonpath='{.metadata.labels}'
kubectl get pod web-server -o jsonpath='{.spec.containers[0].resources}'
kubectl get pod web-server -o jsonpath='{.status.phase}'

# Filter and count with shell:
kubectl get pods -l env=prod --no-headers | wc -l
```

## CKAD Exam Domains (Mapped to Lessons)

- **Application Design & Build** (20%) — Pod creation, labels, container config
- **Application Deployment** (20%) — Deployments, rolling updates, rollbacks
- **Application Observability** (15%) — Logging, monitoring, debugging
- **Application Environment** (15%) — ConfigMaps, Secrets, resource limits
- **Services & Networking** (20%) — Service types, ingress, network policies
- **State Persistence** (10%) — PersistentVolumes, StatefulSets

## Key Files to Modify When Adding Labs

- Create new lessons in `lessonN/` directories
- Each lab: `lessonN/N.M/lab_N.M.yaml` or `lessonN/lab_N.M.yaml`
- No additional configuration files needed; labs are self-contained

## Common kubectl Cheat Sheet (Exam Applicable)

```bash
# Imperative creation (fastest)
kubectl run <name> --image=<image> [options] --dry-run=client -o yaml

# Dry-run preview
kubectl [create/run/apply] ... --dry-run=client -o yaml

# Get with selectors
kubectl get <type> -l <selector> -o [yaml|json|wide|name]

# Introspection (no editor)
kubectl describe <type> <name>
kubectl exec <pod> -- <command>
kubectl logs <pod> [-c <container>]
kubectl get <type> <name> -o jsonpath='<expression>'

# Labels (with --overwrite for replacements)
kubectl label <type> <name> key=value [--overwrite] [-l selector]

# Delete
kubectl delete <type> <name> [--ignore-not-found]
```

## Notes for AI Assistance

- When suggesting lab improvements, prioritize **exam speed** over code elegance
- YAML snippets should include explanatory comments (reflect the teaching style)
- Verification commands are critical — solutions must show how to confirm without opening an editor
- Labs assume a running Kubernetes cluster (minikube/kind/lab environment); assume default namespace unless specified
- The weather-alert project is separate; it's a reference 12-factor application, not part of CKAD exam prep