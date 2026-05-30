# LeaderWorkerSet (LWS) 面试题深度解析

> **适用场景**: Kubernetes 控制器开发、AI/ML 平台工程、云原生推理平台面试
>
> **文档生成日期**: 2026-05-30

---

## 目录

1. [项目理解类问题](#1-项目理解类问题)
2. [控制器设计类问题](#2-控制器设计类问题)
3. [滚动更新类问题](#3-滚动更新类问题)
4. [Gang 调度类问题](#4-gang-调度类问题)
5. [PD 分离类问题](#5-pd-分离类问题)
6. [推理部署类问题](#6-推理部署类问题)
7. [工程实践类问题](#7-工程实践类问题)
8. [系统设计类问题](#8-系统设计类问题)

---

## 1. 项目理解类问题

### Q1: LWS 解决了什么问题？为什么需要它？

**标准答案**:

LWS 解决了 **多主机 LLM 推理的 Pod 编排问题**。传统 Kubernetes 工作负载（Deployment、StatefulSet）管理的是单个 Pod，而 LLM 推理通常需要多个 Pod 协同工作（如 Tensor Parallelism、Pipeline Parallelism）。

**核心痛点**:

1. **组级生命周期**: 一个推理实例由 1 Leader + M Workers 组成，需要作为一个整体管理
2. **故障恢复**: 任意 Pod 失败需要重建整个组，而不是单个 Pod 重启
3. **滚动更新**: 更新时需要保证组级别的可用性，而不是 Pod 级别
4. **拓扑感知**: Leader 和 Workers 需要在同一拓扑域内（如同一机架）
5. **Gang 调度**: 所有 Pod 要么同时调度，要么都不调度，避免资源浪费

**加分回答**:

LWS 是 Kubernetes SIGs 项目，与 llm-d（CNCF sandbox）协同设计，专门针对 AI/ML 推理场景优化。它不是通用的工作负载控制器，而是专门为多主机 LLM 推理设计的领域特定抽象。

---

### Q2: LWS 的两个 CRD 是什么？它们的关系是什么？

**标准答案**:

1. **LeaderWorkerSet (LWS)**: 管理一组 Leader + Worker Pod 的基础单元
2. **DisaggregatedSet (DS)**: 高层编排器，管理多个 LWS 实例用于 PD 分离

**关系**:

```
DisaggregatedSet
    ├── Role "prefill"  →  LeaderWorkerSet A
    └── Role "decode"   →  LeaderWorkerSet B
```

**关键区别**:

| 维度 | LeaderWorkerSet | DisaggregatedSet |
|------|-----------------|------------------|
| 层级 | 基础单元 | 高层编排 |
| 角色 | 单一角色 | 2-10 个角色 |
| 更新 | 单维度滚动更新 | N 维滚动更新 |
| 用途 | 单一类型的推理实例 | Prefill-Decode 分离架构 |

---

### Q3: LeaderWorkerSet 的核心字段有哪些？

**标准答案**:

```go
type LeaderWorkerSetSpec struct {
    Replicas            *int32              // 组数量
    LeaderWorkerTemplate LeaderWorkerTemplate // Pod 模板
    RolloutStrategy     RolloutStrategy     // 滚动更新策略
    StartupPolicy       StartupPolicyType   // 启动策略
    NetworkConfig       *NetworkConfig      // 网络配置
}
```

**每个字段的作用**:

1. **Replicas**: 决定有多少个 Leader-Worker 组，支持 HPA
2. **LeaderWorkerTemplate**: 定义 Leader 和 Worker 的 Pod 模板、组大小、重启策略
3. **RolloutStrategy**: 控制滚动更新的行为（Partition、MaxUnavailable、MaxSurge）
4. **StartupPolicy**: 控制 Worker 何时创建（LeaderCreated vs LeaderReady）
5. **NetworkConfig**: 控制 Headless Service 的创建策略（Shared vs UniquePerReplica）

---

## 2. 控制器设计类问题

### Q4: LWS 的控制器架构是怎样的？为什么需要两个 Reconciler？

**标准答案**:

LWS 有两个 Reconciler：

1. **LeaderWorkerSetReconciler**: 管理 Leader StatefulSet
2. **PodReconciler**: 管理 Worker StatefulSet

**为什么需要两个**:

- **Leader STS 由 LWS Reconciler 直接管理**: 因为 Leader STS 的生命周期与 LWS 对象绑定，数量由 `spec.replicas` 决定
- **Worker STS 由 Pod Reconciler 动态创建**: 因为 Worker STS 依赖 Leader Pod 存活，数量由 `spec.leaderWorkerTemplate.size - 1` 决定

**交互流程**:

```
用户创建 LWS
    │
    ▼
LWS Reconciler 创建 Leader STS (Replicas=3)
    │
    ├── Leader Pod 0 创建
    │   └── Pod Reconciler 创建 Worker STS 0 (Replicas=Size-1)
    │
    ├── Leader Pod 1 创建
    │   └── Pod Reconciler 创建 Worker STS 1 (Replicas=Size-1)
    │
    └── Leader Pod 2 创建
        └── Pod Reconciler 创建 Worker STS 2 (Replicas=Size-1)
```

**加分回答**:

这种设计遵循了 Kubernetes 的控制器模式：
- LWS Reconciler 是 **Level Triggered**：只关心期望状态（LWS Spec）和实际状态（Leader STS）的差异
- Pod Reconciler 是 **Event Driven**：当 Leader Pod 创建时触发，创建对应的 Worker STS

---

### Q5: 为什么使用 Server-Side Apply (SSA)？

**标准答案**:

**问题**: 多个控制器或工具可能同时修改同一个 StatefulSet，导致冲突。

**SSA 的优势**:

1. **原子性**: 更新是原子的，不会出现部分更新
2. **冲突检测**: 自动检测字段冲突
3. **所有权管理**: 每个 FieldManager 声明自己拥有的字段
4. **Force 模式**: 可以强制获取字段所有权

**代码实现**:

```go
r.Patch(ctx, patch, client.Apply, &client.PatchOptions{
    FieldManager: "lws",
    Force:        true,
})
```

**为什么 Force=true**:

在 LWS 场景中，如果用户手动修改了 StatefulSet 的字段，LWS 控制器需要能够覆盖这些修改，确保 StatefulSet 的状态与 LWS Spec 一致。

---

### Q6: ControllerRevision 是如何工作的？

**标准答案**:

**作用**: 追踪 LWS 模板的版本，支持精确的滚动更新和回滚。

**工作流程**:

1. **创建 Revision**: 当 LWS 创建或模板更新时，创建 ControllerRevision 存储当前模板
2. **比较 Revision**: 使用 `revisionutils.EqualRevision` 比较原始字节
3. **语义比较**: 使用 `SetMatchesRevision` 避免误触发滚动更新（如 JSON 序列化顺序不同）
4. **截断 Revision**: 更新完成后清理旧 Revision

**优化: LRU 缓存**:

```go
const maxRevisionEqualityCacheEntries = 10_000

// 缓存语义相等性比较结果，避免重复计算
if cached, ok := r.revisionEqualityCache.Get(key); ok {
    return cached.(bool)
}
```

**面试追问**: 为什么需要语义比较？原始字节比较不够吗？

**回答**: 不够。以下情况会导致字节不同但语义相同：
- JSON 字段顺序不同
- 默认值是否显式设置
- 序列化格式差异

---

### Q7: Pod Reconciler 的主要职责是什么？

**标准答案**:

Pod Reconciler 监听 Pod 变化，主要职责：

1. **创建 Worker StatefulSet**: 当 Leader Pod 创建时，创建对应的 Worker STS
2. **处理 Restart Policy**: 根据策略删除 Leader Pod 触发组重建
3. **创建 PodGroup**: 通过 SchedulerProvider 创建 Gang 调度组
4. **设置独占放置**: 根据 Leader Pod 的拓扑设置 Worker 的 NodeSelector
5. **创建 Headless Service**: 在 UniquePerReplica 模式下为每个组创建服务

**为什么 Worker STS 由 Pod Reconciler 创建而不是 LWS Reconciler**:

- Worker STS 的数量取决于 Leader Pod 的数量
- Worker STS 的名称使用 Leader Pod 的名称
- Worker STS 需要等待 Leader Pod 存在才能创建
- 这种设计解耦了 Leader 和 Worker 的生命周期管理

---

## 3. 滚动更新类问题

### Q8: LWS 的滚动更新是如何工作的？

**标准答案**:

LWS 的滚动更新通过控制 Leader StatefulSet 的 **Partition** 和 **Replicas** 实现。

**核心参数**:

- **Partition**: 从 Partition 到 Replicas-1 的组会被更新
- **MaxUnavailable**: 最大不可用组数
- **MaxSurge**: 最大超出组数

**更新流程**:

```
初始状态: Replicas=5, Partition=0 (所有组都是旧版本)
    │
    ▼  模板更新
    │
计算新的 Partition 和 Replicas
    │
    ▼  设置 STS 的 Partition 和 Replicas
    │
StatefulSet 控制器更新 Pod
    │
    ▼  Pod 就绪
    │
继续推进 Partition
    │
    ▼  所有组更新完成
    │
Partition=0, Replicas=原始值
```

**关键算法**:

```go
// 计算滚动更新的副本数
func calculateRollingUpdateReplicas(lwsReplicas, maxSurge, maxUnavailable, unreadyReplicas int32) int32 {
    burstReplicas := lwsReplicas + maxSurge
    if unreadyReplicas <= maxSurge {
        requiredSurge := nonZeroValue(unreadyReplicas - maxUnavailable)
        return lwsReplicas + requiredSurge
    }
    return burstReplicas
}
```

---

### Q9: Partition 是如何计算的？

**标准答案**:

Partition 的计算基于以下原则：

1. **连续就绪原则**: 从末尾开始计算连续就绪的副本数
2. **最大不可用原则**: 确保不可用副本数不超过 MaxUnavailable
3. **单向移动原则**: Partition 只能从高到低移动，不能回退

**核心算法**:

```go
func rollingUpdatePartition(states []replicaState, stsReplicas, rollingStep, currentPartition int32) int32 {
    // 计算连续就绪的副本数
    continuousReadyReplicas := calculateContinuousReadyReplicas(states)

    // 计算滚动步骤分区
    rollingStepPartition = nonZeroValue(stsReplicas - continuousReadyReplicas - rollingStep)

    // 考虑未就绪副本的影响
    var unavailable int32
    for idx := 0; idx < int(rollingStepPartition); idx++ {
        if !states[idx].ready {
            unavailable++
        }
    }
    partition = rollingStepPartition + unavailable

    // 处理连续未就绪的副本
    for idx := min(partition, stsReplicas-1); idx >= rollingStepPartition; idx-- {
        if !states[idx].ready || states[idx].updated {
            partition = idx
        } else {
            break
        }
    }

    // 单向移动
    return min(partition, currentPartition)
}
```

**面试追问**: 为什么 Partition 只能从高到低移动？

**回答**: 如果 Partition 可以回退，会导致已经更新的组被回滚，违反了滚动更新的语义。用户可以通过手动设置 Partition 来实现回滚。

---

### Q10: MaxSurge 和 MaxUnavailable 是如何配合的？

**标准答案**:

**MaxSurge**: 允许超出期望副本数的最大值
**MaxUnavailable**: 允许不可用副本数的最大值

**配合原则**:

1. **MaxSurge > 0**: 先创建新组，再删除旧组（蓝绿部署风格）
2. **MaxUnavailable > 0**: 先删除旧组，再创建新组（滚动更新风格）
3. **两者都 > 0**: 同时创建新组和删除旧组

**约束条件**:

- MaxSurge 和 MaxUnavailable 不能同时为 0
- MaxSurge 不能超过 Replicas

**示例**:

```
初始状态: Replicas=5, MaxSurge=2, MaxUnavailable=1

Step 1: 创建 2 个新组 (7 个组)
Step 2: 删除 1 个旧组 (6 个组)
Step 3: 创建 1 个新组 (7 个组)
Step 4: 删除 1 个旧组 (6 个组)
...
最终状态: 5 个新组
```

---

### Q11: 如何实现金丝雀发布？

**标准答案**:

使用 **Partition** 字段实现金丝雀发布：

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: my-llm
spec:
  replicas: 10
  rolloutStrategy:
    type: RollingUpdate
    rollingUpdateConfiguration:
      partition: 8  # 只更新 index=8,9 的组
```

**步骤**:

1. **设置 Partition**: 只更新 Partition 到 Replicas-1 的组
2. **观察新版本**: 监控新版本组的行为
3. **推进 Partition**: 如果新版本正常，逐步推进 Partition
4. **完成更新**: Partition=0 时更新完成

**回滚**:

如果新版本有问题，可以：
1. 增大 Partition 值，停止更新
2. 修改模板为旧版本
3. 减小 Partition 值，回滚旧组

---

## 4. Gang 调度类问题

### Q12: 什么是 Gang 调度？为什么需要它？

**标准答案**:

**Gang 调度**: 一组相关 Pod 要么同时被调度，要么都不调度。

**为什么需要**:

在 LLM 推理中，一个推理实例由多个 Pod 组成（如 Tensor Parallelism=8）。如果只有部分 Pod 被调度：
- 被调度的 Pod 会占用资源但无法工作
- 未被调度的 Pod 等待资源
- 整体资源利用率低

**示例**:

```
场景: LWS Size=8, 集群只有 5 个 GPU

没有 Gang 调度:
- 5 个 Pod 被调度，占用 5 个 GPU
- 3 个 Pod 等待
- 推理无法开始，资源浪费

有 Gang 调度:
- 8 个 Pod 都不调度
- 资源留给其他可以完整运行的工作负载
```

---

### Q13: LWS 如何实现 Gang 调度？

**标准答案**:

LWS 通过 **SchedulerProvider** 接口实现 Gang 调度，当前支持 Volcano。

**实现方式**:

1. **创建 PodGroup**: 为每个 Leader-Worker 组创建一个 PodGroup
2. **设置 MinMember**: PodGroup 的最小成员数等于组大小
3. **设置 MinResources**: 预留整个组的资源
4. **绑定生命周期**: PodGroup 通过 OwnerReference 绑定到 Leader Pod

**PodGroup 命名规则**:

```
{lwsName}-{groupIndex}-{revisionHash}

示例: my-llm-0-a1b2c3d4
```

**关键代码**:

```go
// 创建 PodGroup
pg = volcanov1beta1.PodGroup{
    ObjectMeta: metav1.ObjectMeta{
        Name:      pgName,
        Namespace: lws.Namespace,
    },
    Spec: volcanov1beta1.PodGroupSpec{
        MinMember:    *lws.Spec.LeaderWorkerTemplate.Size,
        MinResources: &minResources,
    },
}

// LeaderReady 策略：MinMember=1
if lws.Spec.StartupPolicy == leaderworkerset.LeaderReadyStartupPolicy {
    pg.Spec.MinMember = 1
}

// 绑定到 Leader Pod
ctrl.SetControllerReference(leaderPod, &pg, v.client.Scheme())
```

---

### Q14: LeaderCreated 和 LeaderReady 启动策略对 Gang 调度有什么影响？

**标准答案**:

| 启动策略 | MinMember | MinResources | 行为 |
|----------|-----------|--------------|------|
| LeaderCreated | Size | Leader + (Size-1) * Worker | 所有 Pod 同时调度 |
| LeaderReady | 1 | Leader + (Size-1) * Worker | 先调度 Leader，再调度 Workers |

**LeaderCreated 策略**:

- MinMember = Size
- 所有 Pod 必须同时调度
- 适用于需要严格一致性的场景

**LeaderReady 策略**:

- MinMember = 1
- Leader 可以单独调度
- 适用于 Leader 需要初始化（如加载模型）后再调度 Workers 的场景

**为什么 LeaderReady 的 MinResources 仍然包含所有 Pod**:

如果集群资源不足以调度所有 Worker，仅调度 Leader 也是无意义的。MinResources 确保在调度 Leader 时就预留了整个组的资源。

---

### Q15: Volcano PodGroup 的生命周期是怎样的？

**标准答案**:

```
LWS 创建
    │
    ▼
Leader Pod 创建 (by Leader STS)
    │
    ▼
Pod Reconciler 触发
    │
    ├── 创建 PodGroup (OwnerReference → Leader Pod)
    │
    └── 创建 Worker STS
        │
        ▼
    Worker Pods 创建
    │
    ▼
Volcano 调度器观察 PodGroup
    │
    ├── 检查 MinMember 是否满足
    │   ├── 不满足 → 等待
    │   └── 满足 → 调度所有 Pods
    │
    └── 推理开始
```

**清理机制**:

- PodGroup 通过 OwnerReference 绑定到 Leader Pod
- 当 Leader Pod 被删除时，PodGroup 自动被 GC
- LWS 删除时，所有 Leader Pod 被删除，PodGroup 随之清理

**面试追问**: 为什么 PodGroup 绑定到 Leader Pod 而不是 LWS？

**回答**:
1. 每个组需要独立的 PodGroup，而不是整个 LWS 共享一个
2. PodGroup 的生命周期应该与组的生命周期一致
3. Leader Pod 是组的"代表"，删除 Leader Pod 意味着重建整个组

---

## 5. PD 分离类问题

### Q16: 什么是 PD 分离？为什么需要它？

**标准答案**:

**PD 分离 (Prefill-Decode Disaggregation)**: 将 LLM 推理过程分为两个阶段：

1. **Prefill 阶段**: 处理输入 Token，计算 KV Cache
   - 计算密集型
   - 需要大量 GPU 算力
   - 延迟敏感

2. **Decode 阶段**: 生成输出 Token
   - 内存密集型
   - 需要大量 GPU 显存
   - 吞吐量敏感

**为什么需要**:

| 维度 | 单体架构 | PD 分离架构 |
|------|----------|-------------|
| 资源利用率 | Prefill 和 Decode 混合，资源利用率低 | 独立扩缩容，资源利用率高 |
| 硬件选择 | 统一硬件 | Prefill 用 A100，Decode 用 H100 |
| 扩缩容 | 整体扩缩容 | 独立扩缩容 |
| 故障隔离 | 共享资源 | 独立故障域 |

**示例**:

```
单体架构:
- 8 个 GPU 运行 Prefill + Decode
- Prefill 阶段：GPU 计算满载，显存空闲
- Decode 阶段：GPU 计算空闲，显存满载

PD 分离架构:
- 4 个 A100 运行 Prefill（计算密集型）
- 8 个 H100 运行 Decode（内存密集型）
- 各自按需扩缩容
```

---

### Q17: DisaggregatedSet 的架构是怎样的？

**标准答案**:

DisaggregatedSet 是一个独立的控制器，具有以下组件：

```
DisaggregatedSet Controller
    │
    ├── Planner (规划器)
    │   ├── 计算 N 维滚动更新计划
    │   └── 线性插值算法
    │
    ├── Executor (执行器)
    │   ├── 执行滚动更新计划
    │   └── 检测角色变化
    │
    ├── WorkloadManager (工作负载管理器)
    │   ├── 创建/更新/删除 LWS
    │   └── Revision 命名和管理
    │
    └── ServiceManager (服务管理器)
        ├── 创建 Headless Service
        └── 跨角色通信
```

**为什么是独立子项目**:

1. **独立版本**: DS 可以独立于 LWS 进行版本迭代
2. **独立部署**: DS 可以选择性部署，不影响 LWS
3. **独立依赖**: DS 可能有额外的依赖（如推理框架）
4. **独立团队**: DS 可能由不同的团队维护

---

### Q18: N 维滚动更新算法是如何工作的？

**标准答案**:

**问题**: 多角色之间的滚动更新需要协调，避免所有角色同时更新导致服务不可用。

**算法**: 使用线性插值实现平滑的多角色扩缩容。

**核心函数**:

```go
// 新版本在第 i 步的副本数
func newAtStep(step, target, totalSteps int) int {
    return int(math.Ceil(float64(step) * float64(target) / float64(totalSteps)))
}

// 旧版本在第 i 步的副本数
func oldAtStep(step, source, totalSteps int) int {
    return source - int(math.Floor(float64(step)*float64(source)/float64(totalSteps)))
}
```

**示例**:

```
初始状态: prefill=0, decode=0
目标状态: prefill=4, decode=2
总步数: 4 (取最大目标值)

Step 0: prefill=0, decode=0
Step 1: prefill=1, decode=1
Step 2: prefill=2, decode=1
Step 3: prefill=3, decode=2
Step 4: prefill=4, decode=2
```

**关键特性**:

1. **无状态**: 从观察到的副本数计算步骤，不需要存储中间状态
2. **线性缩放**: 每步变化量与总步数成比例
3. **Surge 约束**: `old + new <= target + maxSurge`
4. **缩放方向**:
   - Scale-up: 使用所有角色的最小步数
   - Scale-down: 使用所有角色的最大步数

**面试追问**: 为什么 Scale-up 用最小步数，Scale-down 用最大步数？

**回答**:
- **Scale-up 用最小步数**: 确保新版本逐步增加，避免一次性创建过多新组
- **Scale-down 用最大步数**: 确保旧版本逐步减少，避免一次性删除过多旧组

---

### Q19: DisaggregatedSet 的 Revision 管理是怎样的？

**标准答案**:

**Revision 计算**: 使用 SHA-256 计算所有角色模板的哈希值。

```go
func computeRevision(ds *DisaggregatedSet) (string, error) {
    data, err := json.Marshal(ds.Spec.Roles)
    hash := sha256.Sum256(data)
    return hex.EncodeToString(hash[:])[:8], nil  // 取前 8 位
}
```

**命名规则**:

```
LWS 名称: {baseName}-{revision}-{role}
示例: my-llm-disagg-a1b2c3d4-prefill

Service 名称: {baseName}-{revision}-{role}-prv
示例: my-llm-disagg-a1b2c3d4-prefill-prv
```

**Revision 管理策略**:

1. **创建新 Revision**: 当任意角色的模板更新时，计算新的 Revision
2. **创建新 LWS**: 为新 Revision 的每个角色创建新的 LWS
3. **滚动更新**: 通过 Planner 协调新旧 LWS 的副本数
4. **清理旧 LWS**: 当旧 Revision 的所有组清空后，删除旧 LWS

**面试追问**: 为什么 DisaggregatedSet 使用 SHA-256 而不是 ControllerRevision？

**回答**:
1. **独立性**: DS 是独立子项目，不想依赖 LWS 的 Revision 机制
2. **简洁性**: SHA-256 计算简单，不需要存储额外的对象
3. **跨角色**: DS 的 Revision 包含所有角色的模板，而不仅仅是单个 LWS

---

## 6. 推理部署类问题

### Q20: 如何使用 LWS 部署 vLLM 推理服务？

**标准答案**:

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: vllm-llama
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2  # 1 Leader + 1 Worker
    leaderTemplate:
      spec:
        containers:
          - name: vllm
            image: vllm/vllm-openai:v0.8.5
            resources:
              limits:
                nvidia.com/gpu: "8"
            args:
              - "--model=meta-llama/Llama-3.1-405B-Instruct"
              - "--tensor-parallel-size=8"
              - "--pipeline-parallel-size=2"
              - "--distributed-executor-backend=ray"
    workerTemplate:
      spec:
        containers:
          - name: vllm
            image: vllm/vllm-openai:v0.8.5
            resources:
              limits:
                nvidia.com/gpu: "8"
            args:
              - "--model=meta-llama/Llama-3.1-405B-Instruct"
              - "--tensor-parallel-size=8"
              - "--pipeline-parallel-size=2"
              - "--distributed-executor-backend=ray"
```

**关键参数**:

1. **size=2**: 1 Leader + 1 Worker
2. **tensor-parallel-size=8**: 每个节点使用 8 个 GPU 进行张量并行
3. **pipeline-parallel-size=2**: 2 个节点进行流水线并行
4. **nvidia.com/gpu: "8"**: 每个节点使用 8 个 GPU

**网络通信**:

- Leader 和 Workers 通过 Headless Service 进行通信
- DNS 名称: `{podName}.{serviceName}`
- 示例: `vllm-llama-0.vllm-llama`, `vllm-llama-0-1.vllm-llama`

---

### Q21: 如何实现拓扑感知的推理部署？

**标准答案**:

使用 **Exclusive Placement** 确保 Leader 和 Workers 在同一拓扑域内。

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: my-llm
  annotations:
    leaderworkerset.sigs.k8s.io/exclusive-topology: topology.kubernetes.io/zone
spec:
  replicas: 2
  leaderWorkerTemplate:
    size: 4
    workerTemplate:
      spec:
        containers:
          - name: worker
            resources:
              limits:
                nvidia.com/gpu: "8"
```

**工作原理**:

1. **Leader Pod 调度**: Scheduler 将 Leader Pod 调度到某个 Node
2. **Pod Webhook 注入**: 读取 Leader Pod 的 Node，获取拓扑值
3. **设置 NodeSelector**: 将拓扑值设置为 Worker STS 的 NodeSelector
4. **Worker Pod 调度**: Workers 被调度到同一拓扑域内的 Node

**拓扑标签示例**:

- `topology.kubernetes.io/zone`: 可用区
- `cloud.google.com/gke-nodepool`: GKE 节点池
- `kubernetes.io/hostname`: 单节点（最严格）

---

### Q22: 如何处理推理服务的故障恢复？

**标准答案**:

LWS 提供三种重启策略：

**1. RecreateGroupOnPodRestart (默认)**

```yaml
restartPolicy: RecreateGroupOnPodRestart
```

- 任意 Pod 重启或容器重启时，删除 Leader Pod
- 触发整个组重建
- 适用于需要严格一致性的场景

**2. RecreateGroupAfterStart**

```yaml
restartPolicy: RecreateGroupAfterStart
```

- 类似上者，但仅在组内所有 Pod 都已启动（非 Pending）后才触发
- 适用于初始部署需要稳定性的场景

**3. None**

```yaml
restartPolicy: None
```

- 仅重启失败的 Pod，不影响其他 Pod
- 适用于可以容忍部分失败的场景

**面试追问**: 为什么默认策略是 RecreateGroupOnPodRestart？

**回答**: LLM 推理通常需要所有 Pod 状态一致。如果一个 Pod 失败并重启，它会丢失状态（如 KV Cache），导致推理结果不一致。重建整个组可以确保所有 Pod 从相同的状态开始。

---

## 7. 工程实践类问题

### Q23: LWS 的测试策略是怎样的？

**标准答案**:

LWS 采用三层测试策略：

**1. 单元测试**

- 与源代码同目录
- 测试单个函数/方法
- 快速执行

```go
func TestCalculateRollingUpdateReplicas(t *testing.T) {
    tests := []struct {
        name           string
        lwsReplicas    int32
        maxSurge       int32
        maxUnavailable int32
        unready        int32
        expected       int32
    }{
        // 测试用例...
    }
    // ...
}
```

**2. 集成测试**

- 使用 controller-runtime 的 envtest 框架
- 测试控制器与 API Server 的交互
- 不需要真实集群

```go
var _ = Describe("LeaderWorkerSet Controller", func() {
    It("should create leader StatefulSet", func() {
        // 创建 LWS
        lws := createLWS(namespace, "test-lws")

        // 验证 Leader STS 被创建
        Eventually(func() bool {
            sts := getLeaderSTS(lws.Name)
            return sts != nil
        }).Should(BeTrue())
    })
})
```

**3. E2E 测试**

- 使用 Kind 集群
- 测试完整的工作流程
- 包括 Gang 调度测试

```bash
# 运行 E2E 测试
make test-e2e

# 运行 Gang 调度 E2E 测试
make test-e2e-gang-scheduling-volcano
```

---

### Q24: LWS 的部署方式有哪些？

**标准答案**:

**1. kubectl + Kustomize**

```bash
# 安装 CRD
make install

# 部署控制器
make deploy

# 卸载
make undeploy
make uninstall
```

**2. Helm**

```bash
# 基础安装
helm install lws charts/lws/ \
  --namespace lws-system \
  --create-namespace

# 启用 Volcano
helm install lws charts/lws/ \
  --namespace lws-system \
  --create-namespace \
  --set gangSchedulingManagement.schedulerProvider=volcano

# 启用 Prometheus
helm install lws charts/lws/ \
  --namespace lws-system \
  --create-namespace \
  --set enablePrometheus=true
```

**3. 从源码构建**

```bash
# 构建二进制
make build

# 构建镜像
make image-build

# 推送镜像
make image-push
```

---

### Q25: LWS 的监控和可观测性是怎样的？

**标准答案**:

**1. Prometheus Metrics**

- 默认禁用，通过 Helm values 启用
- 端口: 8443 (HTTPS)
- 认证: Bearer Token

```yaml
enablePrometheus: true
```

**2. Health Probes**

- 端口: 8081
- 路径: `/healthz`, `/readyz`

**3. Events**

LWS 会生成以下事件：

| 事件 | 触发条件 |
|------|----------|
| CreatingRevision | 创建新的 ControllerRevision |
| GroupsProgressing | 组正在创建 |
| GroupsUpdating | 组正在更新 |
| FailedCreate | 资源创建失败 |
| FailedUpdate | 资源更新失败 |

**4. Status Conditions**

| 条件 | 含义 |
|------|------|
| Available | LWS 可用 |
| Progressing | LWS 正在进行中 |
| UpdateInProgress | LWS 正在执行滚动更新 |

---

## 8. 系统设计类问题

### Q26: 如果让你设计一个类似 LWS 的系统，你会怎么做？

**标准答案**:

**1. 需求分析**

- 多主机 LLM 推理的 Pod 编排
- 组级生命周期管理
- 滚动更新
- Gang 调度
- 拓扑感知

**2. 设计决策**

| 决策 | 选择 | 原因 |
|------|------|------|
| API 设计 | CRD | Kubernetes 原生集成 |
| 控制器框架 | controller-runtime | 标准 Kubernetes 控制器开发框架 |
| Leader 管理 | StatefulSet | 稳定命名、滚动更新 |
| Worker 管理 | StatefulSet | 与 Leader 一致 |
| 版本管理 | ControllerRevision | Kubernetes 原生支持 |
| Gang 调度 | Volcano | 成熟的 Gang 调度器 |
| 更新策略 | Server-Side Apply | 避免冲突 |

**3. 架构设计**

```
┌─────────────────────────────────────┐
│        Controller Manager           │
│                                     │
│  ┌─────────────┐  ┌─────────────┐  │
│  │ LWS         │  │ Pod         │  │
│  │ Reconciler  │  │ Reconciler  │  │
│  └─────────────┘  └─────────────┘  │
│                                     │
│  ┌─────────────┐  ┌─────────────┐  │
│  │ Webhook     │  │ Scheduler   │  │
│  │ (Defaulter  │  │ Provider    │  │
│  │  Validator) │  │ (Volcano)   │  │
│  └─────────────┘  └─────────────┘  │
└─────────────────────────────────────┘
```

**4. 关键设计点**

- **两个 Reconciler**: 解耦 Leader 和 Worker 的生命周期
- **SSA**: 避免多控制器冲突
- **ControllerRevision**: 精确版本管理
- **SchedulerProvider 接口**: 支持多种 Gang 调度器
- **Exclusive Placement**: 拓扑感知调度

---

### Q27: LWS 有什么局限性？如何改进？

**标准答案**:

**局限性**:

1. **单集群**: LWS 仅支持单集群部署，不支持跨集群
2. **无状态管理**: LWS 不管理推理服务的状态（如 KV Cache）
3. **无流量管理**: LWS 不管理推理服务的流量
4. **加速器支持有限**: 仅支持 TPU 和 GPU，不支持其他加速器

**改进方向**:

1. **跨集群支持**: 通过 Federation 或 Karmada 支持跨集群部署
2. **状态管理**: 集成分布式存储（如 Redis）管理推理状态
3. **流量管理**: 集成 Service Mesh（如 Istio）管理推理流量
4. **更多加速器**: 支持昇腾 NPU、AMD GPU 等

---

### Q28: 如何扩展 LWS 支持新的加速器？

**标准答案**:

**步骤**:

1. **创建 Accelerator Utility**

```go
// pkg/utils/accelerators/ascend.go
package accelerators

func AddAscendAnnotations(pod corev1.Pod, annotations map[string]string) {
    // 添加昇腾相关的注解
}

func InjectAscendEnvironmentVariables(pod *corev1.Pod) {
    // 注入 HCCL 相关环境变量
}
```

2. **修改 Pod Webhook**

```go
// pkg/webhooks/pod_webhook.go
func (r *PodWebhook) Default(ctx context.Context, obj runtime.Object) error {
    // ...
    acceleratorutils.AddAscendAnnotations(pod, annotations)
    acceleratorutils.InjectAscendEnvironmentVariables(pod)
    // ...
}
```

3. **定义拓扑标签**

```go
const AscendTopologyKey = "huawei.com/ascend-topology"
```

4. **集成到 Exclusive Placement**

```go
func (r *PodReconciler) setNodeSelectorForWorkerPods(...) {
    // 读取 Leader Pod 的 Node
    // 获取昇腾拓扑标签值
    // 设置 Worker STS 的 NodeSelector
}
```

5. **Volcano 集成**

确保 Volcano 能正确计算 `huawei.com/ascend-910` 资源。

6. **示例配置**

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: ascend-llm
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2
    workerTemplate:
      spec:
        containers:
          - name: worker
            resources:
              limits:
                huawei.com/ascend-910: "8"
```

---

### Q29: LWS 与 Deployment/StatefulSet 有什么区别？

**标准答案**:

| 维度 | Deployment | StatefulSet | LeaderWorkerSet |
|------|------------|-------------|-----------------|
| Pod 关系 | 独立 | 有序 | Leader + Workers |
| 命名 | 随机 | 有序 | Leader + Workers |
| 更新策略 | 滚动更新 | 滚动更新 | 组级滚动更新 |
| 故障恢复 | 单 Pod | 单 Pod | 组级 |
| 网络 | 无 | 稳定 | Headless Service |
| 存储 | 无 | PVC | PVC |
| Gang 调度 | 不支持 | 不支持 | 支持 |
| 拓扑感知 | 不支持 | 不支持 | 支持 |

**LWS 的优势**:

1. **组级抽象**: 天然支持多 Pod 协同工作
2. **故障恢复**: 组级故障恢复，确保一致性
3. **Gang 调度**: 避免资源浪费
4. **拓扑感知**: 确保 Pod 在同一拓扑域内

---

### Q30: LWS 的未来发展方向是什么？

**标准答案**:

**1. 更多加速器支持**

- 昇腾 NPU
- AMD GPU
- Intel GPU

**2. 跨集群支持**

- Federation
- Karmada
- 多云部署

**3. 状态管理**

- KV Cache 管理
- 分布式存储集成

**4. 流量管理**

- Service Mesh 集成
- 智能路由

**5. 更多推理框架支持**

- TensorRT-LLM
- SGLang
- llama.cpp

**6. 性能优化**

- 更智能的调度策略
- 更快的故障恢复
- 更细粒度的更新控制

---

## 附录: 面试准备清单

### 必须掌握的知识点

- [ ] LWS 的核心概念和 API
- [ ] 两个 Reconciler 的职责和交互
- [ ] 滚动更新算法（Partition、MaxSurge、MaxUnavailable）
- [ ] Gang 调度的实现（SchedulerProvider、PodGroup）
- [ ] PD 分离的架构（Planner、Executor、WorkloadManager、ServiceManager）
- [ ] Server-Side Apply 的原理和优势
- [ ] ControllerRevision 的工作原理
- [ ] 拓扑感知调度的实现

### 加分项

- [ ] 能够画出 LWS 的架构图
- [ ] 能够解释滚动更新的每个 Case
- [ ] 能够解释 N 维滚动更新算法
- [ ] 能够设计类似 LWS 的系统
- [ ] 能够分析 LWS 的局限性和改进方向
- [ ] 能够扩展 LWS 支持新的加速器

### 常见追问

1. 为什么需要两个 Reconciler？
2. 为什么使用 SSA？
3. 为什么 PodGroup 绑定到 Leader Pod？
4. 为什么默认策略是 RecreateGroupOnPodRestart？
5. 为什么 Scale-up 用最小步数，Scale-down 用最大步数？

---

*文档生成完成。祝面试顺利！*
