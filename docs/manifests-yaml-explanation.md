# Manifests.yaml 文件详解及 NetworkTopology 的影响

## 一、manifests.yaml 的主要作用

### 1. 什么是 manifests.yaml？
manifests.yaml 是一个包含所有 Kubernetes 资源定义的 YAML 文件，用于部署 LWS 控制器及其相关组件到 Kubernetes 集群。

### 2. 主要包含的资源

```yaml
# 典型的 manifests.yaml 结构
---
# 1. CustomResourceDefinition (CRD)
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: leaderworkersets.leaderworkerset.x-k8s.io
spec:
  # CRD 定义，包含 NetworkTopology 字段的 schema

---
# 2. Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: lws-system

---
# 3. ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lws-controller-manager
  namespace: lws-system

---
# 4. ClusterRole (RBAC 权限)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lws-manager-role
rules:
  - apiGroups: ["leaderworkerset.x-k8s.io"]
    resources: ["leaderworkersets"]
    verbs: ["*"]
  - apiGroups: ["scheduling.volcano.sh"]  # Volcano 权限
    resources: ["podgroups"]
    verbs: ["*"]

---
# 5. ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lws-manager-rolebinding

---
# 6. ConfigMap (控制器配置)
apiVersion: v1
kind: ConfigMap
metadata:
  name: lws-manager-config
  namespace: lws-system
data:
  controller_manager_config.yaml: |
    apiVersion: config.lws.x-k8s.io/v1alpha1
    kind: Configuration
    leaderElection:
      leaderElect: true
    gangSchedulingManagement:
      schedulerProvider: volcano  # 如果使用 Volcano

---
# 7. Deployment (控制器部署)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lws-controller-manager
  namespace: lws-system
spec:
  template:
    spec:
      containers:
      - name: manager
        image: registry.k8s.io/lws/lws:v0.6.1
        args:
        - --config=/controller_manager_config.yaml

---
# 8. Service (Webhook 服务)
apiVersion: v1
kind: Service
metadata:
  name: lws-webhook-service
  namespace: lws-system

---
# 9. ValidatingWebhookConfiguration
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: lws-validating-webhook-configuration

---
# 10. MutatingWebhookConfiguration
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: lws-mutating-webhook-configuration
```

## 二、NetworkTopology 修改对 manifests.yaml 的影响

### ✅ 需要更新的部分

#### 1. **CRD 定义** - 必须更新
```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: leaderworkersets.leaderworkerset.x-k8s.io
spec:
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        properties:
          spec:
            properties:
              networkTopology:  # 新增字段
                description: NetworkTopology defines the network topology configuration
                properties:
                  mode:
                    type: string
                    enum: ["hard", "soft"]
                    default: "hard"
                  highestTierAllowed:
                    type: integer
                    minimum: 0
                type: object
```

#### 2. **RBAC 权限** - 如果使用 Volcano 需要确认
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lws-manager-role
rules:
  # 确保有 Volcano PodGroup 权限
  - apiGroups: ["scheduling.volcano.sh"]
    resources: ["podgroups"]
    verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
```

#### 3. **ConfigMap** - 如果启用 Volcano
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lws-manager-config
  namespace: lws-system
data:
  controller_manager_config.yaml: |
    apiVersion: config.lws.x-k8s.io/v1alpha1
    kind: Configuration
    gangSchedulingManagement:
      schedulerProvider: volcano  # 添加这个配置
```

### ❌ 不需要更新的部分

1. **Deployment** - 控制器镜像包含了新代码，但 Deployment YAML 结构不变
2. **Service** - 不受影响
3. **ServiceAccount** - 不受影响
4. **Namespace** - 不受影响

## 三、如何生成更新的 manifests.yaml

### 方法 1: 使用 make 命令（推荐）
```bash
# 1. 确保代码已更新
make generate     # 生成 deepcopy 等代码
make manifests    # 生成 CRD

# 2. 构建安装文件
make build-installer

# 3. 查看生成的文件
ls -la dist/
# 输出: lws-<version>.yaml
```

### 方法 2: 使用 Kustomize
```bash
# 1. 配置 Volcano provider
cat > config/manager/controller_config_patch.yaml <<EOF
apiVersion: config.lws.x-k8s.io/v1alpha1
kind: Configuration
gangSchedulingManagement:
  schedulerProvider: volcano
EOF

# 2. 更新 kustomization.yaml
cd config/manager
kustomize edit add patch --path controller_config_patch.yaml

# 3. 生成完整的 manifests
cd ../..
kustomize build config/default > manifests.yaml
```

### 方法 3: 使用 Helm
```bash
# 生成 manifests
helm template lws charts/lws \
  --set image.manager.tag=latest \
  --set gangSchedulingManagement.schedulerProvider=volcano \
  > manifests.yaml
```

## 四、验证 manifests.yaml 是否正确

### 1. 检查 CRD 包含 NetworkTopology
```bash
# 从 manifests.yaml 提取 CRD 并检查
grep -A 20 "networkTopology:" manifests.yaml
```

### 2. 检查 RBAC 权限
```bash
# 确认有 Volcano PodGroup 权限
grep -A 5 "scheduling.volcano.sh" manifests.yaml
```

### 3. 检查控制器配置
```bash
# 确认配置了 schedulerProvider
grep -A 2 "gangSchedulingManagement:" manifests.yaml
```

## 五、实际部署步骤

### 1. 生成新的 manifests.yaml
```bash
# 使用上述任一方法生成
make build-installer
mv dist/lws-*.yaml manifests.yaml
```

### 2. 应用到集群
```bash
# 部署所有组件
kubectl apply -f manifests.yaml
```

### 3. 验证部署
```bash
# 检查 CRD
kubectl explain leaderworkerset.spec.networkTopology

# 检查控制器
kubectl logs -n lws-system deployment/lws-controller-manager

# 创建测试资源
kubectl apply -f examples/leaderworkerset-with-topology.yaml
```

## 六、总结

### 您的 NetworkTopology 修改需要更新 manifests.yaml 的部分：

1. **必须更新**：
   - ✅ CRD 定义（包含 NetworkTopology schema）
   - ✅ 控制器镜像（包含新代码）

2. **可能需要更新**：
   - ✅ ConfigMap（如果要启用 Volcano）
   - ✅ RBAC（如果原来没有 Volcano 权限）

3. **不需要更新**：
   - ❌ Deployment 结构
   - ❌ Service
   - ❌ Webhook 配置结构

### 推荐的工作流程：

```bash
# 1. 修改代码
vim api/leaderworkerset/v1/leaderworkerset_types.go

# 2. 生成代码和 CRD
make generate manifests

# 3. 构建镜像
make docker-build docker-push IMG=<your-registry>/lws:latest

# 4. 生成新的 manifests.yaml
make build-installer

# 5. 部署
kubectl apply -f dist/lws-*.yaml

# 6. 验证
kubectl apply -f examples/leaderworkerset-with-topology.yaml
```

这样就能确保 manifests.yaml 包含了所有 NetworkTopology 相关的更新。