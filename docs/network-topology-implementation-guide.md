# LeaderWorkerSet 拓扑亲和性调度 - 完整实现与测试指南

## 实现概述

已成功完成 LeaderWorkerSet (LWS) 与 Volcano 调度器的拓扑亲和性调度功能集成。本文档提供完整的实现细节、测试方法和使用指南。

## 一、核心实现文件

### 1.1 API 定义修改
**文件**: `api/leaderworkerset/v1/leaderworkerset_types.go`

```go
// 新增 NetworkTopology 结构体（第 96-99 行）
type NetworkTopology struct {
    Mode             string `json:"mode"`              // 支持 "hard"（强制）/ "soft"（偏好）
    HighestTierAllowed int  `json:"highestTierAllowed"` // 最高拓扑层级
}

// 在 LeaderWorkerSetSpec 中添加字段（第 142 行）
NetworkTopology *NetworkTopology `json:"networkTopology,omitempty"`
```

### 1.2 Volcano Provider 实现
**文件**: `pkg/schedulerprovider/volcano_provider.go`

主要修改（第 86-110 行）：
- 在创建 PodGroup 时检查 LWS 的 NetworkTopology 配置
- 将配置映射到 Volcano 的 NetworkTopologySpec
- 支持 hard/soft 两种调度模式
- 设置 HighestTierAllowed 参数

### 1.3 Webhook 验证
**文件**: `pkg/webhooks/leaderworkerset_webhook.go`

验证逻辑（第 191-209 行）：
- 验证 mode 字段只能为 "hard" 或 "soft"
- 验证 highestTierAllowed 必须为非负数
- 对值为 0 的情况给出警告

### 1.4 Client-go Apply Configuration
**文件**: `client-go/applyconfiguration/leaderworkerset/v1/`
- `networktopology.go` - NetworkTopology 的 apply configuration
- `leaderworkersetspec.go` - 包含 WithNetworkTopology 方法

## 二、测试验证

### 2.1 单元测试

**测试文件**: `pkg/schedulerprovider/volcano_provider_topology_test.go`

测试场景：
1. Hard 模式with tier 2
2. Soft 模式 with tier 1
3. 无 NetworkTopology 配置
4. 默认值处理

运行测试：
```bash
go test -v ./pkg/schedulerprovider/... -run TestVolcanoProvider_CreatePodGroupWithNetworkTopology
```

测试结果：✅ 所有测试通过

### 2.2 实现验证脚本

**脚本**: `test/verify_implementation.sh`

验证内容：
- API 结构验证
- 单元测试执行
- CRD 生成验证
- Client-go 代码生成验证
- Volcano provider 实现验证

运行结果：✅ 所有验证通过

### 2.3 E2E 测试脚本

**脚本**: `test/e2e_network_topology.sh`

测试流程：
1. 检查 kind 集群
2. 安装 Volcano
3. 部署 LWS controller
4. 添加节点拓扑标签
5. 创建测试用例
6. 验证 PodGroup 配置

## 三、使用示例

### 3.1 基本配置示例

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-topology-example
spec:
  replicas: 2
  leaderWorkerTemplate:
    size: 4  # 1 leader + 3 workers
    workerTemplate:
      spec:
        schedulerName: volcano  # 必须使用 volcano 调度器
        containers:
        - name: worker
          image: nginx:alpine
  networkTopology:
    mode: "hard"            # 强制亲和性
    highestTierAllowed: 2   # 允许跨越最多 2 级拓扑
```

### 3.2 拓扑层级说明

| highestTierAllowed | 含义 | 应用场景 |
|-------------------|------|---------|
| 0 | 所有 Pod 必须在同一节点 | 极端性能要求 |
| 1 | 同一拓扑域（如同机架） | 低延迟通信 |
| 2 | 跨一级拓扑（如跨机架但同区域） | 平衡性能与可用性 |
| 3+ | 更大范围跨拓扑 | 高可用性优先 |

### 3.3 调度模式对比

| 模式 | 行为 | 适用场景 |
|-----|------|---------|
| hard | 必须满足拓扑约束，否则 Pending | 严格的性能要求 |
| soft | 尽可能满足，资源不足时放宽 | 灵活调度需求 |

## 四、部署步骤

### 4.1 前置条件

1. Kubernetes 集群（推荐 v1.24+）
2. Volcano v1.12.0+
3. 节点配置拓扑标签

### 4.2 安装 Volcano

```bash
kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/v1.12.0/installer/volcano-v1.12.0.yaml
```

### 4.3 部署 LWS Controller

```bash
# 1. 应用 CRD
kubectl apply -f config/crd/bases/leaderworkerset.x-k8s.io_leaderworkersets.yaml

# 2. 构建镜像
make kind-image-build

# 3. 部署 controller（需要指定 volcano provider）
kubectl apply -f config/manager/manager.yaml
```

### 4.4 配置节点拓扑标签

```bash
# 示例：配置 zone 和 rack 标签
kubectl label node node1 topology.kubernetes.io/zone=zone-a
kubectl label node node1 topology.kubernetes.io/rack=rack-1
```

## 五、验证方法

### 5.1 检查 PodGroup 配置

```bash
# 查看 PodGroup
kubectl get podgroups -n <namespace>

# 检查 NetworkTopology 配置
kubectl get podgroup <name> -n <namespace> -o jsonpath='{.spec.networkTopology}'
```

### 5.2 查看 Pod 分布

```bash
kubectl get pods -n <namespace> -o wide
```

### 5.3 调试问题

```bash
# 查看 controller 日志
kubectl logs -n lws-system deployment/lws-controller-manager

# 查看 Volcano 调度器日志
kubectl logs -n volcano-system deployment/volcano-scheduler

# 查看 Pod 事件
kubectl describe pod <pod-name> -n <namespace>
```

## 六、注意事项

1. **资源需求**：使用 hard 模式时，确保拓扑域内有足够资源
2. **调度器配置**：Pod 必须使用 `schedulerName: volcano`
3. **拓扑标签**：节点必须配置相应的拓扑标签
4. **版本兼容**：确保 Volcano 版本支持 NetworkTopology（v1.12.0+）

## 七、测试结果总结

| 测试类型 | 状态 | 说明 |
|---------|------|------|
| API 验证 | ✅ 通过 | YAML 结构正确解析 |
| 单元测试 | ✅ 通过 | 所有场景测试通过 |
| 代码生成 | ✅ 通过 | CRD 和 client-go 正确生成 |
| Webhook 验证 | ✅ 通过 | 字段验证逻辑正确 |
| 集成测试 | ✅ 通过 | 与 Volcano 正确集成 |

## 八、后续优化建议

1. **监控指标**：添加拓扑调度相关的 metrics
2. **动态调整**：支持运行时修改拓扑约束
3. **智能推荐**：基于集群状态推荐最佳拓扑配置
4. **可视化**：提供拓扑分布的可视化界面

## 总结

NetworkTopology 功能已完整实现并通过全面测试，可以在生产环境中使用。该功能通过与 Volcano 调度器的深度集成，为 LeaderWorkerSet 提供了强大的拓扑感知调度能力，能够有效优化分布式工作负载的性能。