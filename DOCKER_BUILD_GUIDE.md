# LeaderWorkerSet Docker 镜像构建和部署指南

## 前置准备

### 1. 安装必要工具

```bash
# 检查 Docker 是否安装
docker --version

# 检查 Go 版本（需要 1.24）
go version

# 检查 kubectl 是否安装（用于部署）
kubectl version --client
```

## 构建镜像

### 方法 1: 使用 Makefile（推荐）

#### 1.1 构建单平台镜像（快速）

```bash
# 只构建 linux/amd64 镜像
make image-build IMG=your-registry/lws:test

# 或指定你的镜像仓库
make image-build IMG=docker.io/yourusername/lws:v0.7.1-fix
```

#### 1.2 构建并加载到 Kind（本地测试）

```bash
# 构建并加载到 kind 集群
make kind-image-build IMG=lws:test

# 这会：
# 1. 构建 linux/amd64 镜像
# 2. 自动加载到 kind 集群中
```

#### 1.3 构建多平台镜像

```bash
# 启用 buildx（首次需要）
docker buildx create --name mybuilder --use
docker buildx inspect --bootstrap

# 构建多平台镜像
make image-build IMG=your-registry/lws:test \
  PLATFORMS="linux/amd64,linux/arm64"
```

### 方法 2: 直接使用 Docker 命令

#### 2.1 基础构建

```bash
# 构建镜像
docker build -t lws:test .

# 或指定详细标签
docker build -t your-registry/lws:v0.7.1-fix \
  --build-arg BUILDER_IMAGE=golang:1.24 \
  --build-arg BASE_IMAGE=gcr.io/distroless/static:nonroot \
  .
```

#### 2.2 多平台构建（使用 buildx）

```bash
# 创建 buildx 构建器
docker buildx create --name lws-builder --use

# 构建并推送多平台镜像
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag your-registry/lws:v0.7.1-fix \
  --push \
  .

# 清理构建器
docker buildx rm lws-builder
```

## 推送镜像

### 推送到 Docker Hub

```bash
# 登录 Docker Hub
docker login

# 使用 Makefile 推送
make image-push IMG=docker.io/yourusername/lws:v0.7.1-fix

# 或直接使用 docker 命令
docker push docker.io/yourusername/lws:v0.7.1-fix
```

### 推送到私有仓库

```bash
# 登录私有仓库
docker login your-registry.com

# 构建并推送
make image-push IMG=your-registry.com/lws:v0.7.1-fix
```

## 部署到 Kubernetes

### 1. 安装 CRDs

```bash
# 安装 CRD
make install

# 或使用 kubectl
kubectl apply -f config/crd/bases/
```

### 2. 部署控制器

#### 方法 A: 使用 Makefile

```bash
# 部署到集群（使用你的镜像）
make deploy IMG=your-registry/lws:v0.7.1-fix

# 这会：
# 1. 生成部署清单
# 2. 应用到集群
```

#### 方法 B: 使用 Kustomize

```bash
# 编辑镜像配置
cd config/manager
kustomize edit set image controller=your-registry/lws:v0.7.1-fix

# 生成并应用清单
kustomize build config/default | kubectl apply -f -
```

#### 方法 C: 使用 Helm

```bash
# 如果有 Helm chart
helm install lws ./charts/lws \
  --set image.repository=your-registry/lws \
  --set image.tag=v0.7.1-fix \
  --namespace lws-system \
  --create-namespace
```

### 3. 验证部署

```bash
# 检查 Pod 状态
kubectl get pods -n lws-system

# 查看控制器日志
kubectl logs -n lws-system deployment/lws-controller-manager -f

# 检查 CRD
kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io
```

## 完整示例流程

```bash
# 1. 克隆代码（如果还没有）
git clone https://github.com/kubernetes-sigs/lws.git
cd lws

# 2. 应用你的修改
# （假设修改已完成）

# 3. 构建镜像
export MY_REGISTRY=docker.io/myusername
export MY_TAG=v0.7.1-maxsurge-fix
make image-build IMG=${MY_REGISTRY}/lws:${MY_TAG}

# 4. 推送镜像
docker login
make image-push IMG=${MY_REGISTRY}/lws:${MY_TAG}

# 5. 部署到集群
make install  # 安装 CRDs
make deploy IMG=${MY_REGISTRY}/lws:${MY_TAG}

# 6. 验证
kubectl get pods -n lws-system
kubectl logs -n lws-system deployment/lws-controller-manager
```

## 本地测试（使用 Kind）

```bash
# 1. 创建 kind 集群
make kind-create

# 2. 构建并加载镜像到 kind
make kind-image-build IMG=lws:test

# 3. 部署
make install
make deploy IMG=lws:test

# 4. 测试你的修复
cat <<EOF | kubectl apply -f -
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: test-lws
spec:
  replicas: 6
  rolloutStrategy:
    rollingUpdateConfiguration:
      partition: 9
      maxUnavailable: 2
      maxSurge: 3
  leaderWorkerTemplate:
    size: 2
    workerTemplate:
      spec:
        containers:
        - name: nginx
          image: nginx:latest
EOF

# 5. 观察 Pod 创建
kubectl get pods -w

# 6. 清理
kubectl delete lws test-lws
make kind-delete
```

## 故障排查

### 构建失败

```bash
# 清理 Docker 缓存
docker system prune -a

# 检查 Go 模块
go mod download
go mod tidy

# 重新构建
make clean
make build
make image-build IMG=test:latest
```

### 部署失败

```bash
# 检查命名空间
kubectl get ns lws-system

# 检查 RBAC
kubectl get clusterrole | grep lws
kubectl get clusterrolebinding | grep lws

# 检查 webhook
kubectl get validatingwebhookconfigurations | grep lws
kubectl get mutatingwebhookconfigurations | grep lws

# 查看事件
kubectl get events -n lws-system --sort-by='.lastTimestamp'
```

## 环境变量配置

```bash
# 可选：设置默认值
export IMAGE_REGISTRY=docker.io/yourusername
export IMAGE_NAME=lws
export GIT_TAG=$(git describe --tags --dirty --always)
export IMG=${IMAGE_REGISTRY}/${IMAGE_NAME}:${GIT_TAG}

# 构建
make image-build

# 推送
make image-push
```

## 生产环境建议

1. **使用特定标签**：不要使用 `latest`，使用明确的版本号
2. **多平台支持**：构建支持 amd64 和 arm64 的镜像
3. **镜像扫描**：推送前扫描安全漏洞
4. **私有仓库**：使用企业私有镜像仓库
5. **镜像签名**：使用 cosign 签名镜像

```bash
# 安全扫描示例
trivy image your-registry/lws:v0.7.1-fix

# 签名镜像（使用 cosign）
cosign sign your-registry/lws:v0.7.1-fix
```