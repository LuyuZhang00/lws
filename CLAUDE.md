# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LeaderWorkerSet (LWS) is a Kubernetes API for deploying groups of pods as a unit of replication, designed for AI/ML inference workloads, particularly multi-host inference where LLMs are sharded across multiple devices/nodes.

## Development Commands

### Build and Test
- **Build the controller**: `make build`
- **Run tests**: `make test`
- **Run integration tests**: `make test-integration`
- **Run E2E tests**: `make test-e2e`
- **Run E2E with cert-manager**: `make test-e2e-cert-manager`
- **Run gang scheduling E2E tests**: `make test-e2e-gang-scheduling-volcano`
- **Run a single test**: Use ginkgo with focus, e.g., `KUBEBUILDER_ASSETS="$(./bin/setup-envtest use 1.34.0 -p path)" ./bin/ginkgo --focus="TestName" ./test/integration/...`

### Code Generation
- **Generate manifests (CRDs, RBAC, webhooks)**: `make manifests`
- **Generate code (DeepCopy, client-go)**: `make generate`
- **Update codegen**: `./hack/update-codegen.sh`

### Linting and Verification
- **Run linter**: `make lint`
- **Fix linting issues**: `make lint-fix`
- **Verify all**: `make verify`
- **Format code**: `make fmt`

### Deployment
- **Install CRDs**: `make install`
- **Deploy controller**: `make deploy IMG=<your-image>`
- **Uninstall CRDs**: `make uninstall`
- **Undeploy controller**: `make undeploy`

### Local Development
- **Run controller locally**: `make run`
- **Build and load image for kind**: `make kind-image-build`

## Architecture

### Core Components

1. **API Types** (`api/leaderworkerset/v1/`)
   - `LeaderWorkerSet`: Main CRD defining the group of pods
   - Supports leader/worker pod templates, replicas, rolling updates
   - Network topology configuration for pod scheduling constraints
   - Subgroup policies for organizing pods within groups

2. **Controllers** (`pkg/controllers/`)
   - Main reconciliation loop for LeaderWorkerSet resources
   - Manages StatefulSets for leader and worker pods
   - Handles rolling updates, scaling, and failure recovery
   - Implements exclusive placement and topology-aware scheduling

3. **Webhooks** (`pkg/webhooks/`)
   - Validation and defaulting webhooks for LeaderWorkerSet
   - Enforces constraints and validates configurations
   - Pod mutating webhook for setting labels/annotations

4. **Scheduler Providers** (`pkg/schedulerprovider/`)
   - Integration with different schedulers (e.g., Volcano)
   - Gang scheduling support for all-or-nothing pod scheduling

### Key Design Patterns

- **Dual-template pattern**: Separate templates for leader and worker pods
- **Group management**: Pods grouped with unique hash labels
- **Rolling updates**: Updates performed at group level (all pods in group updated together)
- **Topology-aware placement**: Supports exclusive placement using topology keys
- **Subgroups**: Pods can be organized into subgroups for finer control

### Important Labels and Annotations

- `leaderworkerset.sigs.k8s.io/name`: LeaderWorkerSet name
- `leaderworkerset.sigs.k8s.io/group-index`: Group index (0 to replicas-1)
- `leaderworkerset.sigs.k8s.io/worker-index`: Pod index within group
- `leaderworkerset.sigs.k8s.io/group-key`: Unique hash for pods in same group
- `leaderworkerset.sigs.k8s.io/exclusive-topology`: Topology for exclusive scheduling

### Test Scripts

The repository includes several test scripts in the `test/` directory:
- `test/e2e_network_topology.sh`: E2E tests for network topology features
- `test/fix_network_topology.sh`: Helper for fixing network topology issues
- `test/quick_fix_webhooks.sh`: Quick webhook validation fixes
- `test/verify_implementation.sh`: Implementation verification

## Module Information
- **Module name**: `sigs.k8s.io/lws`
- **Kubernetes version**: 1.34.0 (for envtest)
- **Go version**: Check `go.mod` for current version