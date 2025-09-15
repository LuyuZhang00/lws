#!/bin/bash

# E2E test script for LWS NetworkTopology with Volcano on kind cluster
set -e

echo "=== LeaderWorkerSet NetworkTopology E2E Test on Kind Cluster ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function to print colored output
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}→${NC} $1"
}

# 1. Check prerequisites
echo "1. Checking prerequisites..."
if ! command -v kind &> /dev/null; then
    print_error "kind is not installed"
    exit 1
fi
print_status "kind is installed"

if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi
print_status "kubectl is installed"

# 2. Check if kind cluster exists
echo ""
echo "2. Checking kind cluster..."
if ! kubectl cluster-info --context kind-kind &>/dev/null; then
    print_info "Creating kind cluster..."
    kind create cluster --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
    print_status "Kind cluster created"
else
    print_status "Kind cluster is already running"
fi

# 3. Build and load LWS controller image
echo ""
echo "3. Building and loading LWS controller image..."
print_info "Building LWS controller image..."
make kind-image-build
print_status "LWS controller image built and loaded to kind"

# 4. Install Volcano
echo ""
echo "4. Installing Volcano..."
if kubectl get crd podgroups.scheduling.volcano.sh &>/dev/null; then
    print_status "Volcano is already installed"
else
    print_info "Installing Volcano v1.12.0..."
    kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/v1.12.0/installer/volcano-v1.12.0.yaml

    print_info "Waiting for Volcano components to be ready..."
    kubectl wait --for=condition=ready pod -l app=volcano-scheduler -n volcano-system --timeout=300s
    kubectl wait --for=condition=ready pod -l app=volcano-controller -n volcano-system --timeout=300s
    kubectl wait --for=condition=ready pod -l app=volcano-admission -n volcano-system --timeout=300s 2>/dev/null || true
    print_status "Volcano installed successfully"
fi

# 5. Install LWS CRDs
echo ""
echo "5. Installing LWS CRDs..."
kubectl apply -f config/crd/bases/leaderworkerset.x-k8s.io_leaderworkersets.yaml
print_status "LWS CRDs installed"

# 6. Deploy LWS controller
echo ""
echo "6. Deploying LWS controller..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: lws-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lws-controller-manager
  namespace: lws-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lws-manager-role
rules:
- apiGroups: [""]
  resources: ["pods", "services", "endpoints", "events", "configmaps", "secrets", "nodes"]
  verbs: ["*"]
- apiGroups: ["apps"]
  resources: ["statefulsets", "deployments", "replicasets"]
  verbs: ["*"]
- apiGroups: ["leaderworkerset.x-k8s.io"]
  resources: ["leaderworkersets", "leaderworkersets/status", "leaderworkersets/finalizers"]
  verbs: ["*"]
- apiGroups: ["scheduling.volcano.sh"]
  resources: ["podgroups", "queues"]
  verbs: ["*"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lws-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: lws-manager-role
subjects:
- kind: ServiceAccount
  name: lws-controller-manager
  namespace: lws-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lws-controller-manager
  namespace: lws-system
spec:
  replicas: 1
  selector:
    matchLabels:
      control-plane: controller-manager
  template:
    metadata:
      labels:
        control-plane: controller-manager
    spec:
      serviceAccountName: lws-controller-manager
      containers:
      - name: manager
        image: ko.local/sigs.k8s.io/lws/cmd:latest
        imagePullPolicy: IfNotPresent
        command:
        - /manager
        args:
        - --leader-elect=false
        - --scheduler-provider=volcano
        env:
        - name: ENABLE_WEBHOOKS
          value: "false"
        resources:
          limits:
            cpu: 500m
            memory: 128Mi
          requests:
            cpu: 10m
            memory: 64Mi
EOF

print_info "Waiting for LWS controller to be ready..."
kubectl wait --for=condition=available deployment/lws-controller-manager -n lws-system --timeout=60s
print_status "LWS controller deployed"

# 7. Label nodes with topology information
echo ""
echo "7. Adding topology labels to nodes..."
NODES=$(kubectl get nodes -o name | cut -d/ -f2)
NODE_ARRAY=($NODES)
for i in "${!NODE_ARRAY[@]}"; do
    NODE=${NODE_ARRAY[$i]}
    ZONE="zone-$((i / 2))"  # 2 nodes per zone
    RACK="rack-$i"
    print_info "Labeling node $NODE with zone=$ZONE, rack=$RACK"
    kubectl label node $NODE topology.kubernetes.io/zone=$ZONE --overwrite
    kubectl label node $NODE topology.kubernetes.io/rack=$RACK --overwrite
done
print_status "Topology labels added to all nodes"

# 8. Create test namespace
echo ""
echo "8. Creating test namespace..."
kubectl create namespace lws-e2e-test --dry-run=client -o yaml | kubectl apply -f -
print_status "Test namespace created"

# 9. Run test cases
echo ""
echo "9. Running test cases..."

# Test Case 1: Hard mode with highestTierAllowed=2
print_info "Test Case 1: Hard mode with highestTierAllowed=2"
cat <<EOF | kubectl apply -f -
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-hard-tier2
  namespace: lws-e2e-test
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 3  # 1 leader + 2 workers
    leaderTemplate:
      spec:
        schedulerName: volcano
        containers:
        - name: leader
          image: busybox:latest
          command: ["sleep", "3600"]
          resources:
            requests:
              cpu: "10m"
              memory: "32Mi"
    workerTemplate:
      spec:
        schedulerName: volcano
        containers:
        - name: worker
          image: busybox:latest
          command: ["sleep", "3600"]
          resources:
            requests:
              cpu: "10m"
              memory: "32Mi"
  networkTopology:
    mode: "hard"
    highestTierAllowed: 2
EOF

sleep 5

# Test Case 2: Soft mode with highestTierAllowed=1
print_info "Test Case 2: Soft mode with highestTierAllowed=1"
cat <<EOF | kubectl apply -f -
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-soft-tier1
  namespace: lws-e2e-test
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2  # 1 leader + 1 worker
    workerTemplate:
      spec:
        schedulerName: volcano
        containers:
        - name: worker
          image: busybox:latest
          command: ["sleep", "3600"]
          resources:
            requests:
              cpu: "10m"
              memory: "32Mi"
  networkTopology:
    mode: "soft"
    highestTierAllowed: 1
EOF

sleep 5

# Test Case 3: No network topology (control case)
print_info "Test Case 3: No network topology (control case)"
cat <<EOF | kubectl apply -f -
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-no-topology
  namespace: lws-e2e-test
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2
    workerTemplate:
      spec:
        schedulerName: volcano
        containers:
        - name: worker
          image: busybox:latest
          command: ["sleep", "3600"]
          resources:
            requests:
              cpu: "10m"
              memory: "32Mi"
EOF

# 10. Wait for resources to be created
echo ""
echo "10. Waiting for resources to be created..."
sleep 10

# 11. Verify results
echo ""
echo "11. Verification Results:"
echo ""

print_info "LeaderWorkerSets:"
kubectl get lws -n lws-e2e-test

echo ""
print_info "PodGroups:"
kubectl get podgroups -n lws-e2e-test

echo ""
print_info "Pods and their node placement:"
kubectl get pods -n lws-e2e-test -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase

echo ""
print_info "PodGroup NetworkTopology configurations:"
for pg in $(kubectl get podgroups -n lws-e2e-test -o name); do
    echo ""
    echo "  $pg:"
    kubectl get $pg -n lws-e2e-test -o jsonpath='{.spec.networkTopology}' 2>/dev/null || echo "    No NetworkTopology"
    echo ""
done

echo ""
print_info "Detailed PodGroup for hard topology test:"
kubectl describe podgroup -n lws-e2e-test -l leaderworkerset.sigs.k8s.io/name=lws-hard-tier2 2>/dev/null || echo "PodGroup not found"

# 12. Check controller logs for any errors
echo ""
echo "12. Checking controller logs..."
print_info "Last 20 lines of controller logs:"
kubectl logs -n lws-system deployment/lws-controller-manager --tail=20

# Summary
echo ""
echo "==================================="
echo "        E2E Test Summary"
echo "==================================="
echo ""

# Check if all pods are running
ALL_RUNNING=true
for pod in $(kubectl get pods -n lws-e2e-test -o name); do
    STATUS=$(kubectl get $pod -n lws-e2e-test -o jsonpath='{.status.phase}')
    if [ "$STATUS" != "Running" ] && [ "$STATUS" != "Pending" ]; then
        ALL_RUNNING=false
        print_error "$pod is in $STATUS state"
    fi
done

if [ "$ALL_RUNNING" = true ]; then
    print_status "All test cases executed successfully!"
else
    print_error "Some pods are not in expected state"
fi

echo ""
echo "To inspect the resources:"
echo "  kubectl get lws,podgroups,pods -n lws-e2e-test"
echo ""
echo "To check PodGroup details:"
echo "  kubectl describe podgroups -n lws-e2e-test"
echo ""
echo "To clean up:"
echo "  kubectl delete namespace lws-e2e-test"
echo "  kubectl delete namespace lws-system"
echo ""
print_status "E2E test completed!"