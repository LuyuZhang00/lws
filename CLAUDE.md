# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LeaderWorkerSet (LWS) is a Kubernetes API that provides a mechanism to deploy groups of pods as units (called replicas). It's specifically designed for AI/ML inference workloads where models are sharded across multiple devices and nodes. This is part of the kubernetes-sigs organization.

## Key Commands

### Build and Development
```bash
make build                  # Build the manager binary
make generate              # Generate code (DeepCopy, CRD manifests, etc.)
make manifests             # Generate CRD manifests
make fmt                   # Format Go code
make lint                  # Run golangci-lint
make vet                   # Run go vet
```

### Testing
```bash
make test                  # Run unit tests
make test-integration      # Run integration tests
make test-e2e              # Run e2e tests with kind
make test-e2e-gang-scheduling-volcano  # Test gang scheduling with Volcano
ginkgo -v -r test/e2e/...  # Run specific e2e test with verbose output
```

### Deployment and Installation
```bash
make install               # Install CRDs into cluster
make uninstall            # Uninstall CRDs from cluster
make deploy               # Deploy controller to cluster
make undeploy             # Undeploy controller from cluster
make kind-image-build     # Build Docker image for kind testing
make docker-build         # Build Docker image
make docker-push          # Push Docker image
```

### Local Development with Kind
```bash
make kind-create          # Create kind cluster
make kind-image-build     # Build and load image into kind
make kind-load            # Load image into kind cluster
```

## Architecture and Structure

### Core Components

1. **API Types** (`api/leaderworkerset/v1/`):
   - `leaderworkerset_types.go`: Main CRD types defining LeaderWorkerSet spec and status
   - Supports dual pod templates (leader and worker)
   - Implements scale subresource for HPA integration

2. **Controller** (`pkg/controllers/`):
   - `leaderworkerset_controller.go`: Main reconciliation logic
   - `pod_controller.go`: Manages pod lifecycle
   - `statefulset_controller.go`: Manages underlying StatefulSets
   - Uses controller-runtime for Kubernetes reconciliation

3. **Webhook** (`pkg/webhooks/`):
   - `leaderworkerset_webhook.go`: Validation and defaulting webhooks
   - Validates spec changes and rolling update configurations
   - Sets defaults for unspecified fields

4. **Utils** (`pkg/utils/`):
   - Pod management utilities
   - Labels and annotations handling
   - Status calculation helpers

### Key Design Patterns

1. **Group Replica Model**: Each replica consists of 1 leader + N workers as a scheduling unit
2. **StatefulSet Backend**: Uses StatefulSets for stable network identities
3. **Topology Awareness**: Supports exclusive placement and topology domain spreading
4. **Rolling Updates**: Group-level coordinated updates with configurable partitions

### Integration Points

1. **Volcano Scheduler**: Gang scheduling support via PodGroup resources
2. **HPA**: Scale subresource enables horizontal pod autoscaling
3. **Service Discovery**: Headless services for stable network identities

## Testing Strategy

- **Unit Tests**: Focus on controller logic and utilities
- **Integration Tests**: Test controller with fake API server
- **E2E Tests**: Full deployment scenarios on kind clusters
- **Gang Scheduling Tests**: Specific tests for Volcano integration

Run specific test files:
```bash
go test ./pkg/controllers/... -v
ginkgo -focus="specific test name" test/e2e/...
```

## Important Configuration

- **Go Version**: 1.24.0 (latest)
- **Kubernetes Version**: 1.29.x for testing
- **Required Tools**: controller-gen, kustomize, envtest, ginkgo, kind
- **Container Platforms**: linux/arm64, linux/amd64, linux/s390x, linux/ppc64le

## Common Development Workflows

### Adding New Features
1. Modify API types in `api/leaderworkerset/v1/`
2. Run `make generate manifests` to update generated code
3. Implement controller logic in `pkg/controllers/`
4. Add unit tests alongside implementation
5. Add integration/e2e tests as needed
6. Run `make fmt lint test` before committing

### Debugging Controllers
```bash
# Run controller locally against cluster
make install
make run

# Check controller logs
kubectl logs -n lws-system deployment/lws-controller-manager
```

### Working with Examples
Examples are in `examples/` directory:
- `llamacpp/`: LlamaCpp inference setup
- `sglang/`: SGLang deployment
- `tensorrt-llm/`: TensorRT-LLM configuration
- `vllm/`: vLLM deployment

## Release and Versioning

- Semantic versioning (currently v0.7.0)
- Release artifacts include manifests, Helm charts, and container images
- Multi-arch support for all major platforms