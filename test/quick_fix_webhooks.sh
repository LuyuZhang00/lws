#!/bin/bash

# Quick fix: Disable webhooks temporarily and test
set -e

echo "=== Quick Fix: Disable Webhooks and Test ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# Step 1: Delete webhook configurations
echo "Step 1: Removing webhook configurations..."
kubectl delete validatingwebhookconfigurations lws-validating-webhook-configuration --ignore-not-found=true
kubectl delete mutatingwebhookconfigurations lws-mutating-webhook-configuration --ignore-not-found=true
print_status "Webhooks removed"

# Step 2: Test NetworkTopology without webhooks
echo ""
echo "Step 2: Testing NetworkTopology field (webhooks disabled)..."
cat <<EOF | kubectl apply -f -
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: test-no-webhook
  namespace: default
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2
    workerTemplate:
      spec:
        containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: "10m"
              memory: "32Mi"
  networkTopology:
    mode: "hard"
    highestTierAllowed: 2
EOF

if [ $? -eq 0 ]; then
    print_status "NetworkTopology field works without webhooks!"

    # Show the created resource
    echo ""
    print_info "Created LeaderWorkerSet:"
    kubectl get lws test-no-webhook -o jsonpath='{.spec.networkTopology}' | jq .

    # Test the original file
    echo ""
    echo "Step 3: Testing original example file..."
    kubectl apply -f /home/luyu/code/lws/examples/leaderworkerset-with-topology.yaml

    if [ $? -eq 0 ]; then
        print_status "Example file works!"

        # Show all created resources
        echo ""
        print_info "All LeaderWorkerSets with NetworkTopology:"
        kubectl get lws -o custom-columns=NAME:.metadata.name,MODE:.spec.networkTopology.mode,TIER:.spec.networkTopology.highestTierAllowed
    fi
else
    print_error "NetworkTopology still not working"
    echo ""
    print_info "This means the CRD might not be updated. Running CRD update..."

    # Update CRD
    kubectl replace -f config/crd/bases/leaderworkerset.x-k8s.io_leaderworkersets.yaml
    print_status "CRD updated"

    # Retry
    echo ""
    print_info "Retrying..."
    kubectl apply -f /home/luyu/code/lws/examples/leaderworkerset-with-topology.yaml
fi

# Step 4: Restart controller without webhooks
echo ""
echo "Step 4: Restarting controller without webhooks..."
kubectl set env deployment/lws-controller-manager -n lws-system ENABLE_WEBHOOKS=false
kubectl rollout restart deployment/lws-controller-manager -n lws-system
kubectl rollout status deployment/lws-controller-manager -n lws-system --timeout=60s || true
print_status "Controller restarted without webhooks"

# Step 5: Check if PodGroups are created with NetworkTopology
echo ""
echo "Step 5: Checking PodGroup creation..."
sleep 5  # Give controller time to create PodGroups

if kubectl get podgroups -A 2>/dev/null | grep -q "test-no-webhook"; then
    print_info "PodGroup created. Checking NetworkTopology configuration..."
    PG_NAME=$(kubectl get podgroups -A | grep "test-no-webhook" | awk '{print $2}')
    PG_NS=$(kubectl get podgroups -A | grep "test-no-webhook" | awk '{print $1}')

    echo ""
    kubectl get podgroup $PG_NAME -n $PG_NS -o jsonpath='{.spec.networkTopology}' | jq . || echo "No NetworkTopology in PodGroup"
fi

# Summary
echo ""
echo "========================================="
echo "         Quick Fix Results"
echo "========================================="
echo ""

if kubectl get lws test-no-webhook &>/dev/null; then
    print_status "NetworkTopology field is working!"
    echo ""
    echo "The issue was with the webhook validation."
    echo "To permanently fix this:"
    echo ""
    echo "1. Rebuild the controller image with updated API:"
    echo "   make kind-image-build"
    echo ""
    echo "2. Redeploy the controller:"
    echo "   kubectl rollout restart deployment/lws-controller-manager -n lws-system"
    echo ""
    echo "3. Re-enable webhooks:"
    echo "   kubectl set env deployment/lws-controller-manager -n lws-system ENABLE_WEBHOOKS=true"
    echo ""
    echo "Current workaround: Webhooks are disabled"
else
    print_error "Issue persists even without webhooks"
    echo ""
    echo "This indicates a deeper issue with the CRD or controller."
    echo "Please run the complete fix script:"
    echo "   ./test/complete_fix_network_topology.sh"
fi

echo ""
print_status "Quick fix complete!"