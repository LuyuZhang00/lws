# LeaderWorkerSet 拓扑亲和性调度实现方案

## 概述

本方案实现了 LeaderWorkerSet (LWS) 与 Volcano 调度器的拓扑亲和性调度功能，通过新增 `spec.networkTopology` 字段来配置调度规则。

## 实现细节

### 1. API 定义 (`api/leaderworkerset/v1/leaderworkerset_types.go`)

新增了 `NetworkTopology` 结构体：

```go
type NetworkTopology struct {
    Mode             string `json:"mode"`              // 支持 "hard"（强制）/ "soft"（偏好）
    HighestTierAllowed int  `json:"highestTierAllowed"` // 最高拓扑层级，如 2 表示支持两级拓扑
}
```

在 `LeaderWorkerSetSpec` 中添加字段：

```go
type LeaderWorkerSetSpec struct {
    // ... 其他字段
    NetworkTopology *NetworkTopology `json:"networkTopology,omitempty"`
}
```

### 2. Volcano Provider 集成 (`pkg/schedulerprovider/volcano_provider.go`)

在创建 PodGroup 时，将 LWS 的 NetworkTopology 配置映射到 Volcano 的 NetworkTopologySpec：

```go
func (v *VolcanoProvider) CreatePodGroupIfNotExists(ctx context.Context, lws *leaderworkerset.LeaderWorkerSet, leaderPod *corev1.Pod) error {
    // ... 创建 PodGroup 逻辑

    if lws.Spec.NetworkTopology != nil {
        pg.Spec.NetworkTopology = &volcanov1beta1.NetworkTopologySpec{}

        // 映射 mode 字段
        switch lws.Spec.NetworkTopology.Mode {
        case "hard":
            pg.Spec.NetworkTopology.Mode = volcanov1beta1.HardNetworkTopologyMode
        case "soft":
            pg.Spec.NetworkTopology.Mode = volcanov1beta1.SoftNetworkTopologyMode
        default:
            pg.Spec.NetworkTopology.Mode = volcanov1beta1.HardNetworkTopologyMode
        }

        // 设置 HighestTierAllowed
        if lws.Spec.NetworkTopology.HighestTierAllowed > 0 {
            highestTier := lws.Spec.NetworkTopology.HighestTierAllowed
            pg.Spec.NetworkTopology.HighestTierAllowed = &highestTier
        }
    }
}
```

### 3. Webhook 验证 (`pkg/webhooks/leaderworkerset_webhook.go`)

添加了对 NetworkTopology 字段的验证：

- 验证 `mode` 只能为 "hard" 或 "soft"
- 验证 `highestTierAllowed` 必须为非负数
- 对 `highestTierAllowed` 为 0 的情况给出警告（表示所有 Pod 必须在同一节点）

### 4. 工作原理

#### 4.1 调度流程

1. **LWS 创建**：用户创建带有 `networkTopology` 配置的 LeaderWorkerSet
2. **PodGroup 创建**：当 Leader Pod 被创建时，PodController 调用 VolcanoProvider 创建对应的 PodGroup，其中包含 NetworkTopology 配置
3. **Volcano 调度**：Volcano 调度器根据 PodGroup 的 NetworkTopology 配置进行拓扑感知调度
4. **Pod 调度**：所有属于同一 PodGroup 的 Pod（Leader 和 Workers）将根据拓扑约束被调度

#### 4.2 拓扑层级说明

`highestTierAllowed` 参数控制允许的最高拓扑层级：

- **0**：所有 Pod 必须在同一节点（通常不推荐）
- **1**：所有 Pod 必须在同一拓扑域（如同一机架、同一可用区）
- **2**：允许跨越一级拓扑域（如跨机架但在同一区域）
- **3+**：允许更大范围的跨拓扑调度

#### 4.3 调度模式

- **hard 模式**：强制亲和性，必须满足拓扑约束才能调度。如果无法满足约束，Pod 将保持 Pending 状态
- **soft 模式**：偏好模式，尽可能满足拓扑约束，但在资源不足时可以放宽约束

## 使用示例

### 示例 1：强制两级拓扑调度

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-hard-topology
spec:
  replicas: 2
  leaderWorkerTemplate:
    size: 4
    workerTemplate:
      spec:
        containers:
        - name: worker
          image: nginx:latest
  networkTopology:
    mode: "hard"
    highestTierAllowed: 2
```

### 示例 2：偏好单拓扑域调度

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-soft-topology
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 8
    workerTemplate:
      spec:
        containers:
        - name: worker
          image: nginx:latest
  networkTopology:
    mode: "soft"
    highestTierAllowed: 1
```

## 前置条件

1. **Volcano 调度器**：集群必须安装并配置 Volcano 调度器（版本 >= v1.12.0）
2. **拓扑标签**：节点必须配置适当的拓扑标签（如 `topology.kubernetes.io/zone`、`topology.kubernetes.io/region` 等）
3. **Volcano HyperNode**：如果使用自定义拓扑，需要配置 Volcano 的 HyperNode CRD

## 注意事项

1. **资源需求**：使用 hard 模式时，确保拓扑域内有足够的资源，否则 Pod 将无法调度
2. **性能影响**：严格的拓扑约束可能会降低调度灵活性，影响资源利用率
3. **与其他特性的兼容性**：NetworkTopology 可以与 LWS 的其他特性（如 SubGroup、ExclusivePlacement）同时使用

## 监控和调试

1. **查看 PodGroup 状态**：
   ```bash
   kubectl get podgroups -n <namespace>
   kubectl describe podgroup <podgroup-name> -n <namespace>
   ```

2. **查看 Volcano 调度日志**：
   ```bash
   kubectl logs -n volcano-system deployment/volcano-scheduler
   ```

3. **检查 Pod 调度事件**：
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   ```

## 未来改进

1. **动态拓扑调整**：支持根据集群负载动态调整拓扑约束
2. **更细粒度的控制**：支持为 Leader 和 Worker 设置不同的拓扑约束
3. **拓扑感知的自动扩缩容**：基于拓扑域的资源使用情况进行智能扩缩容