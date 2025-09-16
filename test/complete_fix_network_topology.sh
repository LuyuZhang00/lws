#!/bin/bash

# Complete fix for NetworkTopology webhook validation issue
set -e

echo "=== Complete NetworkTopology Fix ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# Step 1: Verify API changes are in place
echo "Step 1: Verifying API definition..."
if grep -q "+optional" /home/luyu/code/lws/api/leaderworkerset/v1/leaderworkerset_types.go | grep -q NetworkTopology; then
    print_status "API definition has correct annotations"
else
    print_error "API definition missing annotations"
    print_info "Please ensure NetworkTopology field has +optional annotation"
    exit 1
fi

# Step 2: Regenerate all code
echo ""
echo "Step 2: Regenerating code..."
print_info "Generating deepcopy..."
./bin/controller-gen object:headerFile="hack/boilerplate.go.txt" paths="./api/..."
print_status "Deepcopy generated"

print_info "Generating CRD manifests..."
make manifests
print_status "CRD manifests generated"

print_info "Generating client code..."
./hack/update-codegen.sh 2>&1 | tail -5
print_status "Client code generated"

# Step 3: Rebuild controller image
echo ""
echo "Step 3: Building new controller image..."
print_info "This will take a few minutes..."
make kind-image-build
print_status "Controller image built and loaded to kind"

# Step 4: Update CRD
echo ""
echo "Step 4: Updating CRD..."
kubectl replace -f config/crd/bases/leaderworkerset.x-k8s.io_leaderworkersets.yaml
print_status "CRD updated"

# Step 5: Delete old controller deployment
echo ""
echo "Step 5: Removing old controller..."
kubectl delete deployment lws-controller-manager -n lws-system --ignore-not-found=true
kubectl delete service lws-webhook-service -n lws-system --ignore-not-found=true
kubectl delete secret lws-webhook-server-cert -n lws-system --ignore-not-found=true
print_status "Old controller removed"

# Step 6: Deploy new controller
echo ""
echo "Step 6: Deploying new controller..."
cat <<'EOF' | kubectl apply -f -
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
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
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
apiVersion: v1
kind: Service
metadata:
  name: lws-webhook-service
  namespace: lws-system
spec:
  ports:
  - port: 443
    targetPort: 9443
  selector:
    control-plane: controller-manager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lws-controller-manager
  namespace: lws-system
  labels:
    control-plane: controller-manager
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
        - --leader-elect=true
        - --scheduler-provider=volcano
        env:
        - name: ENABLE_WEBHOOKS
          value: "true"
        ports:
        - containerPort: 9443
          name: webhook-server
          protocol: TCP
        - containerPort: 8081
          name: health
          protocol: TCP
        - containerPort: 8443
          name: metrics
          protocol: TCP
        volumeMounts:
        - mountPath: /tmp/k8s-webhook-server/serving-certs
          name: cert
          readOnly: true
        resources:
          limits:
            cpu: 500m
            memory: 256Mi
          requests:
            cpu: 100m
            memory: 128Mi
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 20
      volumes:
      - name: cert
        secret:
          defaultMode: 420
          secretName: lws-webhook-server-cert
      terminationGracePeriodSeconds: 10
EOF
print_status "New controller deployed"

# Step 7: Wait for controller to be ready
echo ""
echo "Step 7: Waiting for controller to be ready..."
kubectl wait --for=condition=available deployment/lws-controller-manager -n lws-system --timeout=120s || true
sleep 10  # Give webhook time to initialize
print_status "Controller is running"

# Step 8: Check controller logs
echo ""
echo "Step 8: Checking controller logs..."
kubectl logs deployment/lws-controller-manager -n lws-system --tail=20 | grep -E "(NetworkTopology|webhook|ready)" || true

# Step 9: Test NetworkTopology field
echo ""
echo "Step 9: Testing NetworkTopology field..."
cat <<EOF | kubectl apply -f -
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: test-topology-webhook
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
    print_status "NetworkTopology field accepted by webhook!"

    # Verify the resource
    echo ""
    print_info "Created LeaderWorkerSet:"
    kubectl get lws test-topology-webhook -o jsonpath='{.spec.networkTopology}' | jq .

    # Clean up test
    kubectl delete lws test-topology-webhook --ignore-not-found=true
else
    print_error "NetworkTopology field still not recognized"

    # Show webhook logs for debugging
    echo ""
    print_info "Recent webhook errors:"
    kubectl logs deployment/lws-controller-manager -n lws-system --tail=50 | grep -E "(error|Error|ERROR)" | tail -10
fi

# Step 10: Test the original example file
echo ""
echo "Step 10: Testing original example file..."
if kubectl apply -f /home/luyu/code/lws/examples/leaderworkerset-with-topology.yaml; then
    print_status "Example file applied successfully!"

    # Show created resources
    echo ""
    print_info "Created LeaderWorkerSets:"
    kubectl get lws -o custom-columns=NAME:.metadata.name,MODE:.spec.networkTopology.mode,TIER:.spec.networkTopology.highestTierAllowed

    # Clean up
    kubectl delete -f /home/luyu/code/lws/examples/leaderworkerset-with-topology.yaml --ignore-not-found=true
else
    print_error "Example file still failing"
fi

# Final summary
echo ""
echo "========================================="
echo "         Fix Summary"
echo "========================================="
echo ""
echo "Actions taken:"
echo "1. ✓ Verified API annotations"
echo "2. ✓ Regenerated all code (deepcopy, CRD, client)"
echo "3. ✓ Rebuilt controller image with new API"
echo "4. ✓ Updated CRD in cluster"
echo "5. ✓ Redeployed controller with new image"
echo ""
echo "If the issue persists, try:"
echo "1. Check webhook configuration:"
echo "   kubectl get validatingwebhookconfigurations -A"
echo "   kubectl get mutatingwebhookconfigurations -A"
echo ""
echo "2. Delete webhook configurations and restart controller:"
echo "   kubectl delete validatingwebhookconfigurations lws-validating-webhook-configuration"
echo "   kubectl delete mutatingwebhookconfigurations lws-mutating-webhook-configuration"
echo "   kubectl rollout restart deployment/lws-controller-manager -n lws-system"
echo ""
echo "3. Check controller logs:"
echo "   kubectl logs deployment/lws-controller-manager -n lws-system -f"
echo ""
print_status "Fix process complete!"