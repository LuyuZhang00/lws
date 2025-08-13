#!/bin/bash
# 快速构建和测试 LWS 修复版本的脚本

# 设置变量
REGISTRY="${REGISTRY:-docker.io/yourusername}"  # 替换为你的仓库
TAG="${TAG:-v0.7.1-maxsurge-partition-fix}"
IMG="${REGISTRY}/lws:${TAG}"

echo "========================================="
echo "Building LeaderWorkerSet Controller"
echo "Image: ${IMG}"
echo "========================================="

# 1. 确保代码是最新的
echo "Step 1: Building binary..."
make build

# 2. 构建 Docker 镜像
echo "Step 2: Building Docker image..."
make image-build IMG=${IMG}

# 3. 可选：推送到仓库
read -p "Do you want to push the image to registry? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Step 3: Pushing image to registry..."
    docker login ${REGISTRY}
    make image-push IMG=${IMG}
fi

# 4. 部署到集群
read -p "Do you want to deploy to current Kubernetes cluster? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Step 4: Deploying to Kubernetes..."
    
    # 检查集群连接
    if ! kubectl cluster-info &> /dev/null; then
        echo "Error: Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    # 安装 CRDs
    echo "Installing CRDs..."
    make install
    
    # 部署控制器
    echo "Deploying controller..."
    make deploy IMG=${IMG}
    
    # 等待部署就绪
    echo "Waiting for deployment to be ready..."
    kubectl wait --for=condition=available --timeout=60s \
        deployment/lws-controller-manager -n lws-system
    
    # 显示状态
    echo "Deployment status:"
    kubectl get pods -n lws-system
fi

echo "========================================="
echo "Build completed!"
echo "Image: ${IMG}"
echo ""
echo "To test the fix, create a LWS with:"
echo "  partition > replicas (e.g., partition=9, replicas=6)"
echo "========================================="

# 5. 可选：创建测试资源
read -p "Do you want to create a test LeaderWorkerSet? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Creating test LeaderWorkerSet..."
    cat <<EOF | kubectl apply -f -
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: test-maxsurge-partition
spec:
  replicas: 6
  rolloutStrategy:
    type: RollingUpdate
    rollingUpdateConfiguration:
      partition: 9  # 测试 partition > replicas
      maxUnavailable: 2
      maxSurge: 3
  leaderWorkerTemplate:
    size: 2
    workerTemplate:
      spec:
        containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
EOF
    
    echo "Watching pods creation (press Ctrl+C to stop)..."
    kubectl get pods -l leaderworkerset.sigs.k8s.io/name=test-maxsurge-partition -w
fi