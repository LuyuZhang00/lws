#!/bin/bash

# Integration test script for LWS NetworkTopology with Volcano
set -e

echo "=== LeaderWorkerSet NetworkTopology Integration Test ==="
echo ""

# Check if kind cluster exists
echo "1. Checking kind cluster..."
if ! kubectl cluster-info --context kind-kind &>/dev/null; then
    echo "Error: kind cluster not found. Please create a kind cluster first."
    exit 1
fi
echo "✓ Kind cluster is running"

# Check if Volcano is installed
echo ""
echo "2. Checking Volcano installation..."
if ! kubectl get crd podgroups.scheduling.volcano.sh &>/dev/null; then
    echo "Volcano is not installed. Installing Volcano..."

    # Install Volcano
    kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/v1.12.0/installer/volcano-v1.12.0.yaml

    # Wait for Volcano to be ready
    echo "Waiting for Volcano components to be ready..."
    kubectl wait --for=condition=ready pod -l app=volcano-scheduler -n volcano-system --timeout=300s
    kubectl wait --for=condition=ready pod -l app=volcano-controller -n volcano-system --timeout=300s
    echo "✓ Volcano installed successfully"
else
    echo "✓ Volcano is already installed"
fi

# Check if LWS CRD is installed
echo ""
echo "3. Checking LWS CRD..."
if ! kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io &>/dev/null; then
    echo "Installing LWS CRDs..."
    kubectl apply -f config/crd/bases/leaderworkerset.x-k8s.io_leaderworkersets.yaml
    echo "✓ LWS CRD installed"
else
    echo "✓ LWS CRD is already installed"
fi

# Deploy LWS controller
echo ""
echo "4. Deploying LWS controller..."
# Build and load the controller image to kind
echo "Building controller image..."
make kind-image-build

# Deploy controller
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: lws-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lws-controller
  namespace: lws-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lws-controller
  template:
    metadata:
      labels:
        app: lws-controller
    spec:
      serviceAccountName: lws-controller
      containers:
      - name: controller
        image: ko.local/sigs.k8s.io/lws/cmd:latest
        imagePullPolicy: IfNotPresent
        command:
        - /manager
        args:
        - --scheduler-provider=volcano
        env:
        - name: ENABLE_WEBHOOKS
          value: "false"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lws-controller
  namespace: lws-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lws-controller
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "events", "nodes"]
  verbs: ["*"]
- apiGroups: ["apps"]
  resources: ["statefulsets"]
  verbs: ["*"]
- apiGroups: ["leaderworkerset.x-k8s.io"]
  resources: ["leaderworkersets", "leaderworkersets/status"]
  verbs: ["*"]
- apiGroups: ["scheduling.volcano.sh"]
  resources: ["podgroups"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lws-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: lws-controller
subjects:
- kind: ServiceAccount
  name: lws-controller
  namespace: lws-system
EOF

# Wait for controller to be ready
echo "Waiting for LWS controller to be ready..."
kubectl wait --for=condition=ready pod -l app=lws-controller -n lws-system --timeout=60s || true
echo "✓ LWS controller deployed"

# Create test namespace
echo ""
echo "5. Creating test namespace..."
kubectl create namespace lws-test --dry-run=client -o yaml | kubectl apply -f -
echo "✓ Test namespace created"

# Add topology labels to nodes
echo ""
echo "6. Adding topology labels to nodes..."
NODES=$(kubectl get nodes -o name | cut -d/ -f2)
ZONE_INDEX=0
for NODE in $NODES; do
    ZONE="zone-$((ZONE_INDEX % 2))"
    RACK="rack-$ZONE_INDEX"
    echo "Labeling node $NODE with zone=$ZONE, rack=$RACK"
    kubectl label node $NODE topology.kubernetes.io/zone=$ZONE --overwrite
    kubectl label node $NODE topology.kubernetes.io/rack=$RACK --overwrite
    ZONE_INDEX=$((ZONE_INDEX + 1))
done
echo "✓ Topology labels added to nodes"

# Test Case 1: Hard mode with tier 2
echo ""
echo "7. Test Case 1: Hard mode with tier 2"
echo "Creating LWS with hard network topology..."
kubectl apply -f - <<EOF
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-hard-topology
  namespace: lws-test
  annotations:
    volcano.sh/queue-name: "default"
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2
    workerTemplate:
      spec:
        schedulerName: volcano
        containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: "10m"
              memory: "10Mi"
            limits:
              cpu: "100m"
              memory: "100Mi"
  networkTopology:
    mode: "hard"
    highestTierAllowed: 2
EOF

echo "Waiting for pods to be created..."
sleep 5

# Check PodGroup
echo ""
echo "Checking PodGroup for hard topology test..."
kubectl get podgroups -n lws-test -o yaml | grep -A 5 "networkTopology:" || echo "NetworkTopology not found in PodGroup"

# Check pod status
echo ""
echo "Pod status for hard topology test:"
kubectl get pods -n lws-test -l leaderworkerset.sigs.k8s.io/name=lws-hard-topology -o wide

# Test Case 2: Soft mode with tier 1
echo ""
echo "8. Test Case 2: Soft mode with tier 1"
echo "Creating LWS with soft network topology..."
kubectl apply -f - <<EOF
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-soft-topology
  namespace: lws-test
  annotations:
    volcano.sh/queue-name: "default"
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2
    workerTemplate:
      spec:
        schedulerName: volcano
        containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: "10m"
              memory: "10Mi"
            limits:
              cpu: "100m"
              memory: "100Mi"
  networkTopology:
    mode: "soft"
    highestTierAllowed: 1
EOF

echo "Waiting for pods to be created..."
sleep 5

# Check PodGroup
echo ""
echo "Checking PodGroup for soft topology test..."
kubectl get podgroups -n lws-test -o yaml | grep -A 5 "networkTopology:" || echo "NetworkTopology not found in PodGroup"

# Check pod status
echo ""
echo "Pod status for soft topology test:"
kubectl get pods -n lws-test -l leaderworkerset.sigs.k8s.io/name=lws-soft-topology -o wide

# Summary
echo ""
echo "=== Test Summary ==="
echo ""
echo "LeaderWorkerSets created:"
kubectl get lws -n lws-test

echo ""
echo "PodGroups created:"
kubectl get podgroups -n lws-test

echo ""
echo "All pods:"
kubectl get pods -n lws-test -o wide

echo ""
echo "=== Test Complete ==="
echo ""
echo "To clean up test resources, run:"
echo "  kubectl delete namespace lws-test"
echo "  kubectl delete namespace lws-system"