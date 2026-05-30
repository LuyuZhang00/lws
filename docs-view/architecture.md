# LeaderWorkerSet (LWS) 项目架构深度解析

> **版本**: v0.8.0 | **Kubernetes**: v1.36.x | **Go**: 1.26 | **controller-runtime**: v0.24.1
>
> **模块**: `sigs.k8s.io/lws`
>
> **文档生成日期**: 2026-05-30

---

## 目录

1. [项目概述与定位](#1-项目概述与定位)
2. [系统架构总览](#2-系统架构总览)
3. [目录结构与文件作用详解](#3-目录结构与文件作用详解)
4. [核心 API 类型定义](#4-核心-api-类型定义)
5. [控制器架构与调谐逻辑](#5-控制器架构与调谐逻辑)
6. [Webhook 机制](#6-webhook-机制)
7. [Volcano 与 Gang 调度](#7-volcano-与-gang-调度)
8. [PD 分离 (DisaggregatedSet)](#8-pd-分离-disaggregatedset)
9. [昇腾卡相关分析](#9-昇腾卡相关分析)
10. [关键优化技术总结](#10-关键优化技术总结)
11. [部署与构建系统](#11-部署与构建系统)
12. [测试体系](#12-测试体系)
13. [KEP 特性提案索引](#13-kep-特性提案索引)

---

## 1. 项目概述与定位

### 1.1 项目背景

LeaderWorkerSet (LWS) 是 Kubernetes SIGs (Special Interest Groups) 下的一个项目，提供了一个面向 **AI/ML 推理工作负载** 的自定义资源定义 (CRD)。其核心设计理念是将一组 Pod（1 个 Leader + M 个 Worker）作为一个不可分割的调度单元进行管理，特别针对 **多主机 LLM 推理** 场景。

### 1.2 核心价值

- **Pod 组抽象**: 将传统的单 Pod 管理提升为 "Leader + Workers" 组管理
- **AI/ML 推理优化**: 原生支持 Tensor Parallelism、Pipeline Parallelism 等分布式推理模式
- **故障恢复**: 组级别的故障恢复策略，确保分布式推理的一致性
- **滚动更新**: 支持 maxSurge/maxUnavailable 的精细化滚动更新
- **拓扑感知**: 支持独占式拓扑调度，确保 Pod 组在物理拓扑上的亲和性
- **PD 分离**: 通过 DisaggregatedSet 支持 Prefill-Decode 分离的推理架构

### 1.3 两个 CRD 的关系

```
DisaggregatedSet (高层编排)
    ├── Role "prefill"  →  LeaderWorkerSet A
    └── Role "decode"   →  LeaderWorkerSet B
                              ├── Leader Pod (StatefulSet)
                              └── Worker Pods (StatefulSet)
```

---

## 2. 系统架构总览

### 2.1 整体架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              lws-system namespace                        │   │
│  │                                                          │   │
│  │  ┌─────────────────────────────────────────────────┐     │   │
│  │  │           Controller Manager (Pod)               │     │   │
│  │  │                                                  │     │   │
│  │  │  ┌──────────────────┐  ┌──────────────────┐     │     │   │
│  │  │  │ LWS Reconciler   │  │ Pod Reconciler   │     │     │   │
│  │  │  │                  │  │                  │     │     │   │
│  │  │  │ • Leader STS     │  │ • Worker STS     │     │     │   │
│  │  │  │ • Headless Svc   │  │ • Restart Policy │     │     │   │
│  │  │  │ • Rolling Update │  │ • PodGroup       │     │     │   │
│  │  │  │ • Status Update  │  │ • Exclusive Plc  │     │     │   │
│  │  │  └──────────────────┘  └──────────────────┘     │     │   │
│  │  │                                                  │     │   │
│  │  │  ┌──────────────────┐  ┌──────────────────┐     │     │   │
│  │  │  │ DS Controller    │  │ SchedulerProvider│     │     │   │
│  │  │  │ (Stub)           │  │ (Volcano)        │     │     │   │
│  │  │  └──────────────────┘  └──────────────────┘     │     │   │
│  │  │                                                  │     │   │
│  │  │  ┌──────────────────┐  ┌──────────────────┐     │     │   │
│  │  │  │ LWS Webhook      │  │ Pod Webhook      │     │     │   │
│  │  │  │ • Defaulter      │  │ • Defaulter      │     │     │   │
│  │  │  │ • Validator      │  │ • Validator      │     │     │   │
│  │  │  └──────────────────┘  └──────────────────┘     │     │   │
│  │  └─────────────────────────────────────────────────┘     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │           User Workloads namespace                       │   │
│  │                                                          │   │
│  │  LeaderWorkerSet: my-llm                                 │   │
│  │  ┌─────────────────────────────────────────────┐         │   │
│  │  │  Leader STS: my-llm (Replicas=3)            │         │   │
│  │  │  ├── my-llm-0  (Leader Pod, worker-index=0) │         │   │
│  │  │  ├── my-llm-1  (Leader Pod, worker-index=0) │         │   │
│  │  │  └── my-llm-2  (Leader Pod, worker-index=0) │         │   │
│  │  └─────────────────────────────────────────────┘         │   │
│  │                                                          │   │
│  │  Worker STS per Leader (created by Pod Reconciler):      │   │
│  │  ┌─────────────────────────────────────────────┐         │   │
│  │  │  Worker STS: my-llm-0 (Replicas=Size-1)     │         │   │
│  │  │  ├── my-llm-0-1 (Worker Pod, worker-index=1)│         │   │
│  │  │  ├── my-llm-0-2 (Worker Pod, worker-index=2)│         │   │
│  │  │  └── my-llm-0-3 (Worker Pod, worker-index=3)│         │   │
│  │  └─────────────────────────────────────────────┘         │   │
│  │                                                          │   │
│  │  Headless Service: my-llm                                │   │
│  │  ├── my-llm-0.my-lls    (DNS for leader-0)              │   │
│  │  ├── my-llm-0-1.my-lls  (DNS for worker-0-1)            │   │
│  │  └── ...                                                 │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Volcano Scheduler (if enabled)                          │   │
│  │  ┌─────────────────────────────────────────────┐         │   │
│  │  │  PodGroup per replica                        │         │   │
│  │  │  • MinMember = Size                          │         │   │
│  │  │  • MinResources = leader + (size-1)*worker   │         │   │
│  │  │  • OwnerReference → leader pod               │         │   │
│  │  └─────────────────────────────────────────────┘         │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 核心组件交互流程

```
用户创建 LeaderWorkerSet
        │
        ▼
┌───────────────────┐
│  LWS Webhook      │  ← 设置默认值、校验
│  (Defaulter +     │
│   Validator)      │
└───────┬───────────┘
        │
        ▼
┌───────────────────┐
│  LWS Reconciler   │  ← 核心调谐
│                   │
│  1. 获取/创建 Revision
│  2. 计算 rollingUpdate 参数
│  3. SSA 创建/更新 Leader STS
│  4. 创建 Headless Service
│  5. 更新 Status
└───────┬───────────┘
        │
        ▼  Leader Pod 被创建
┌───────────────────┐
│  Pod Webhook      │  ← 注入标签、环境变量、调度器元数据
│  (Defaulter)      │
└───────┬───────────┘
        │
        ▼
┌───────────────────┐
│  Pod Reconciler   │  ← 处理 Leader Pod
│                   │
│  1. 处理 Restart Policy
│  2. 创建 PodGroup (Volcano)
│  3. 创建 Worker STS
│  4. 设置 Exclusive Placement
└───────────────────┘
```

### 2.3 关键设计决策

| 决策 | 原因 |
|------|------|
| Leader STS 管理 Leader Pod | 利用 StatefulSet 的稳定命名和滚动更新能力 |
| Worker STS 由 Pod Reconciler 创建 | Worker 依赖 Leader 存活，需要动态创建 |
| 使用 Server-Side Apply | 避免冲突，支持多控制器协作 |
| ControllerRevision 版本管理 | 精确追踪模板变更，支持语义比较 |
| SchedulerProvider 接口抽象 | 支持多种调度器（Volcano 及未来扩展） |

---

## 3. 目录结构与文件作用详解

### 3.1 顶层目录

```
/home/luyuzhang/code/lws/
├── cmd/                          # 主程序入口
│   └── main.go                   # 组合控制器管理器（LWS + DS）
├── api/                          # CRD 类型定义
│   ├── leaderworkerset/v1/       # LWS API 类型
│   ├── disaggregatedset/v1/      # DS API 类型
│   └── config/v1alpha1/          # 控制器配置类型
├── pkg/                          # 核心业务逻辑
│   ├── controllers/              # 控制器实现
│   ├── webhooks/                 # Webhook 实现
│   ├── schedulerprovider/        # 调度器提供者接口
│   └── utils/                    # 工具函数
├── client-go/                    # 自动生成的客户端代码
├── config/                       # Kustomize 部署清单
├── charts/                       # Helm Chart
├── disaggregatedset/             # DS 独立子项目
├── test/                         # 集成/E2E 测试
├── docs/                         # 示例部署
├── site/                         # Hugo 文档站点
├── keps/                         # KEP 特性提案
├── hack/                         # 构建脚本
└── .github/                      # CI 工作流
```

### 3.2 `cmd/` — 程序入口

**`cmd/main.go`** 是组合控制器管理器的入口点，负责：

1. **注册 Scheme**: `leaderworkersetv1`、`disaggregatedsetv1`、`configapi`、`volcanov1beta1`
2. **创建 Manager**: 使用 controller-runtime 创建统一的控制器管理器
3. **注册控制器**:
   - `LeaderWorkerSetReconciler` — Leader StatefulSet 管理
   - `PodReconciler` — Worker StatefulSet 创建、Restart Policy、Gang 调度
   - `DisaggregatedSetReconciler` — Stub 实现
4. **注册 Webhook**: LWS、Pod、DS 的 Defaulter 和 Validator
5. **初始化 SchedulerProvider**: 根据配置创建 Volcano Provider
6. **启动证书管理**: 内置证书轮换或 cert-manager

### 3.3 `api/` — CRD 类型定义

#### 3.3.1 `api/leaderworkerset/v1/`

| 文件 | 作用 |
|------|------|
| `leaderworkerset_types.go` | 核心类型：`LeaderWorkerSet`、`LeaderWorkerSetSpec`、`LeaderWorkerSetStatus` |
| `condition_types.go` | 条件类型定义（Available、Progressing、UpdateInProgress） |
| `defaults.go` | 默认值逻辑 |
| `groupversion_info.go` | GroupVersion 注册 |
| `zz_generated.deepcopy.go` | 自动生成的 DeepCopy 方法 |

#### 3.3.2 `api/disaggregatedset/v1/`

| 文件 | 作用 |
|------|------|
| `disaggregatedset_types.go` | 核心类型：`DisaggregatedSet`、`DisaggregatedSetSpec`、`DisaggregatedSetStatus` |
| `groupversion_info.go` | GroupVersion 注册 |
| `zz_generated.deepcopy.go` | 自动生成的 DeepCopy 方法 |

#### 3.3.3 `api/config/v1alpha1/`

| 文件 | 作用 |
|------|------|
| `configuration_types.go` | 控制器配置类型：`Configuration`、`GangSchedulingManagement` |
| `defaults.go` | 配置默认值 |
| `groupversion_info.go` | GroupVersion 注册 |

### 3.4 `pkg/` — 核心业务逻辑

#### 3.4.1 `pkg/controllers/`

| 文件 | 作用 |
|------|------|
| `leaderworkerset_controller.go` | LWS 主控制器：Leader STS 管理、滚动更新、状态更新 |
| `pod_controller.go` | Pod 控制器：Worker STS 创建、Restart Policy、PodGroup 创建 |
| `disaggregatedset/disaggregatedset_controller.go` | DS 控制器（Stub） |

#### 3.4.2 `pkg/webhooks/`

| 文件 | 作用 |
|------|------|
| `leaderworkerset_webhook.go` | LWS Webhook：默认值设置、校验规则 |
| `pod_webhook.go` | Pod Webhook：标签注入、环境变量注入、调度器元数据注入 |
| `disaggregatedset/disaggregatedset_webhook.go` | DS Webhook：校验规则 |

#### 3.4.3 `pkg/schedulerprovider/`

| 文件 | 作用 |
|------|------|
| `interface.go` | `SchedulerProvider` 接口定义 |
| `volcano_provider.go` | Volcano 实现：PodGroup 创建、元数据注入 |

#### 3.4.4 `pkg/utils/`

| 文件/目录 | 作用 |
|-----------|------|
| `accelerators/tpu.go` | TPU 环境变量注入 |
| `controller/controller_utils.go` | 控制器工具函数 |
| `pod/pod_utils.go` | Pod 工具函数（状态判断、标签读取） |
| `revision/revision_utils.go` | Revision 管理工具（创建、比较、截断） |
| `statefulset/statefulset_utils.go` | StatefulSet 工具函数 |

### 3.5 `client-go/` — 自动生成的客户端

```
client-go/
├── applyconfiguration/          # Apply Configuration
├── clientset/                   # 类型化客户端
├── informers/                   # Informer 工厂
└── listers/                     # Lister 接口
```

### 3.6 `config/` — Kustomize 部署清单

| 目录 | 作用 |
|------|------|
| `crd/bases/` | CRD YAML 定义 |
| `crd/patches/` | CA 注入和 Webhook 补丁 |
| `default/` | 默认 Kustomize overlay |
| `manager/` | 控制器管理器 Deployment 和 Configuration |
| `rbac/` | RBAC 角色和绑定 |
| `webhook/` | Webhook Service 和配置 |
| `certmanager/` | cert-manager Certificate |
| `internalcert/` | 内置证书 Secret |
| `prometheus/` | Prometheus ServiceMonitor |
| `components/volcano/` | Volcano RBAC 补丁组件 |
| `components/prometheus/` | Prometheus 监控组件 |
| `samples/` | 示例 YAML |

### 3.7 `charts/` — Helm Chart

```
charts/lws/
├── Chart.yaml                   # Chart 元数据 (v0.1.0, appVersion v0.8.0)
├── values.yaml                  # 默认配置值
├── crds/                        # CRD 定义
└── templates/
    ├── manager/                 # Deployment, ConfigMap, Service
    ├── rbac/                    # ClusterRole, ClusterRoleBinding, SA
    ├── webhook/                 # Webhook 配置
    ├── certmanager/             # Certificate 资源
    └── prometheus/              # ServiceMonitor
```

### 3.8 `disaggregatedset/` — DS 独立子项目

```
disaggregatedset/
├── cmd/main.go                  # 独立二进制入口
├── internal/controller/         # 完整控制器实现
│   ├── disaggregatedset_controller.go  # 主调谐器
│   ├── planner.go               # N 维滚动更新规划器
│   ├── executor.go              # 执行器
│   ├── workload_manager.go      # LWS 工作负载管理
│   └── service_manager.go       # Headless Service 管理
├── internal/webhook/            # Webhook 实现
├── charts/                      # 独立 Helm Chart
├── config/                      # Kustomize 清单
└── test/                        # 测试
```

---

## 4. 核心 API 类型定义

### 4.1 LeaderWorkerSet API

#### 4.1.1 LeaderWorkerSetSpec

```go
type LeaderWorkerSetSpec struct {
    // replicas: Leader-Worker 组的数量（默认 1）
    // 支持 HPA 子资源
    Replicas *int32

    // leaderWorkerTemplate: Leader/Worker Pod 模板
    LeaderWorkerTemplate LeaderWorkerTemplate

    // rolloutStrategy: 滚动更新策略
    RolloutStrategy RolloutStrategy

    // startupPolicy: 启动策略
    // - LeaderCreated: Leader 创建后立即创建 Worker
    // - LeaderReady: Leader 就绪后才创建 Worker
    StartupPolicy StartupPolicyType

    // networkConfig: 网络配置
    NetworkConfig *NetworkConfig
}
```

#### 4.1.2 LeaderWorkerTemplate

```go
type LeaderWorkerTemplate struct {
    // leaderTemplate: Leader Pod 模板（可选，默认使用 workerTemplate）
    LeaderTemplate *corev1.PodTemplateSpec

    // workerTemplate: Worker Pod 模板
    WorkerTemplate corev1.PodTemplateSpec

    // size: 每组的 Pod 总数（Leader + Workers）
    // 最小值为 1（仅 Leader）
    Size *int32

    // restartPolicy: 重启策略
    // - RecreateGroupOnPodRestart: 任意 Pod 重启时重建整个组
    // - RecreateGroupAfterStart: 组内所有 Pod 启动后才触发重建
    // - None: 仅重启失败的 Pod（类似 StatefulSet）
    RestartPolicy RestartPolicyType

    // subGroupPolicy: 子组策略
    SubGroupPolicy *SubGroupPolicy

    // volumeClaimTemplates: PVC 模板
    VolumeClaimTemplates []corev1.PersistentVolumeClaim

    // persistentVolumeClaimRetentionPolicy: PVC 回收策略
    PersistentVolumeClaimRetentionPolicy *appsv1.StatefulSetPersistentVolumeClaimRetentionPolicy
}
```

#### 4.1.3 RolloutStrategy

```go
type RolloutStrategy struct {
    // type: 仅支持 RollingUpdate
    Type RolloutStrategyType

    // rollingUpdateConfiguration: 滚动更新配置
    RollingUpdateConfiguration *RollingUpdateConfiguration
}

type RollingUpdateConfiguration struct {
    // partition: 分区点
    // 从 Partition 到 Replicas-1 的组会被更新
    Partition *int32

    // maxUnavailable: 最大不可用数（绝对值或百分比）
    MaxUnavailable intstr.IntOrString

    // maxSurge: 最大超出数（绝对值或百分比）
    MaxSurge intstr.IntOrString
}
```

#### 4.1.4 标签与注解常量

| 常量 | 值 | 用途 |
|------|------|------|
| `SetNameLabelKey` | `leaderworkerset.sigs.k8s.io/name` | 标记所属 LWS |
| `GroupIndexLabelKey` | `leaderworkerset.sigs.k8s.io/group-index` | 组索引 |
| `WorkerIndexLabelKey` | `leaderworkerset.sigs.k8s.io/worker-index` | Worker 索引（Leader=0） |
| `RevisionKey` | `leaderworkerset.sigs.k8s.io/template-revision-hash` | Revision 追踪 |
| `ExclusiveKeyAnnotationKey` | `leaderworkerset.sigs.k8s.io/exclusive-topology` | 独占拓扑键 |
| `SubGroupExclusiveKeyAnnotationKey` | `leaderworkerset.sigs.k8s.io/subgroup-exclusive-topology` | 子组独占拓扑键 |
| `SizeAnnotationKey` | `leaderworkerset.sigs.k8s.io/size` | 组大小注解 |
| `ReplicasAnnotationKey` | `leaderworkerset.sigs.k8s.io/replicas` | 副本数注解 |
| `LeaderPodNameAnnotationKey` | `leaderworkerset.sigs.k8s.io/leader-name` | Leader Pod 名称 |
| `GroupUniqueHashLabelKey` | `leaderworkerset.sigs.k8s.io/group-key` | 组唯一哈希 |
| `SubGroupIndexLabelKey` | `leaderworkerset.sigs.k8s.io/subgroup-index` | 子组索引 |

#### 4.1.5 环境变量

| 环境变量 | 用途 |
|----------|------|
| `LWS_LEADER_ADDRESS` | Leader Pod 地址 |
| `LWS_GROUP_SIZE` | 组大小 |
| `LWS_WORKER_INDEX` | Worker 索引 |

#### 4.1.6 LeaderWorkerSetStatus

```go
type LeaderWorkerSetStatus struct {
    // conditions: 状态条件
    Conditions []metav1.Condition

    // readyReplicas: 就绪组数
    ReadyReplicas int32

    // updatedReplicas: 已更新组数
    UpdatedReplicas int32

    // replicas: 总组数
    Replicas int32

    // hpaPodSelector: HPA 使用的 Pod 选择器
    HPAPodSelector string

    // observedGeneration: 最近观察到的 Generation
    ObservedGeneration int64
}
```

#### 4.1.7 状态条件类型

| 条件类型 | 含义 |
|----------|------|
| `Available` | LWS 可用，至少最小可用组数在运行 |
| `Progressing` | LWS 正在进行中（创建、扩缩容） |
| `UpdateInProgress` | LWS 正在执行滚动更新 |

### 4.2 DisaggregatedSet API

#### 4.2.1 DisaggregatedSetSpec

```go
type DisaggregatedSetSpec struct {
    // roles: 角色列表（2-10 个）
    // 每个角色有唯一名称和独立的 LWS 模板
    Roles []DisaggregatedRoleSpec
}

type DisaggregatedRoleSpec struct {
    // name: 角色唯一标识符
    Name string

    // LeaderWorkerSetTemplateSpec: 内嵌的 LWS 模板
    // 注意：RolloutStrategy.Type 必须为 RollingUpdate
    // Partition 字段不允许设置
    leaderworkerset.LeaderWorkerSetTemplateSpec
}
```

#### 4.2.2 DisaggregatedSetStatus

```go
type DisaggregatedSetStatus struct {
    // roleStatuses: 每个角色的状态
    RoleStatuses []RoleStatus

    // conditions: 标准条件（Available, Progressing, Degraded）
    Conditions []metav1.Condition
}

type RoleStatus struct {
    Name           string
    Replicas       int32
    ReadyReplicas  int32
    UpdatedReplicas int32
}
```

#### 4.2.3 校验规则

- 角色名称必须唯一
- Replicas 必须全为零或全为非零
- RolloutStrategy.Type 必须为 RollingUpdate（或空）
- Partition 字段不允许设置

### 4.3 Configuration API

```go
type Configuration struct {
    ControllerManager          `json:",inline"`
    InternalCertManagement     *InternalCertManagement
    GangSchedulingManagement   *GangSchedulingManagement
    ClientConnection           *ClientConnection
    TLSOptions                 *TLSOptions
}

type GangSchedulingManagement struct {
    SchedulerProvider *string  // 例如 "volcano"
}
```

---

## 5. 控制器架构与调谐逻辑

### 5.1 LeaderWorkerSet Reconciler

#### 5.1.1 核心职责

1. **管理 Leader StatefulSet**: 使用 Server-Side Apply 创建/更新
2. **管理 Headless Service**: 根据 SubdomainPolicy 创建共享或独立服务
3. **滚动更新**: 基于 Partition 的精细控制
4. **Revision 管理**: 使用 ControllerRevision 追踪模板版本
5. **状态更新**: 计算并更新 Available/Progressing/UpdateInProgress 条件

#### 5.1.2 Reconcile 流程详解

```
Reconcile(ctx, req)
    │
    ├── 1. 获取 LeaderWorkerSet 对象
    │
    ├── 2. 获取 Leader StatefulSet
    │
    ├── 3. 获取/创建 ControllerRevision
    │   ├── 如果 STS 存在，从 STS 的 annotation 获取 revisionKey
    │   ├── 如果 Revision 不存在，创建新的
    │   └── 升级场景：创建缺失的 Revision
    │
    ├── 4. 检测是否有更新
    │   ├── 创建新的 Revision
    │   └── 比较当前 Revision 和目标 Revision
    │
    ├── 5. 计算滚动更新参数 (partition, replicas)
    │   ├── Case 1: STS 未创建 → partition=0, replicas=lwsReplicas
    │   ├── Case 2: 新的滚动更新 → 先处理扩缩容
    │   ├── Case 3: 正常状态 → partition=0, replicas=lwsReplicas
    │   ├── Case 4: 滚动更新中副本数变化
    │   └── Case 5: 滚动更新进行中 → 计算新的 partition
    │
    ├── 6. SSA 创建/更新 Leader StatefulSet
    │
    ├── 7. 创建 Headless Service（如果不存在）
    │
    └── 8. 更新 Status
        ├── 更新 Replicas/ReadyReplicas/UpdatedReplicas
        ├── 更新 Conditions
        └── 如果更新完成，截断旧 Revision
```

#### 5.1.3 滚动更新算法详解

滚动更新是 LWS 最复杂的部分之一，涉及以下核心算法：

**`rollingUpdateParameters` 函数**:

```go
func (r *LeaderWorkerSetReconciler) rollingUpdateParameters(
    ctx context.Context,
    lws *leaderworkerset.LeaderWorkerSet,
    sts *appsv1.StatefulSet,
    revisionKey string,
    leaderWorkerSetUpdated bool,
) (stsPartition int32, replicas int32, err error)
```

**Case 分析**:

| Case | 条件 | partition | replicas |
|------|------|-----------|----------|
| 1 | STS 未创建 | 0 | lwsReplicas |
| 2 | LWS 刚更新 | min(lwsReplicas, stsReplicas) | wantReplicas() |
| 3 | 正常状态（已完成） | 0 | lwsReplicas |
| 4 | 滚动更新中副本数变化 | min(partition, burstReplicas) | wantReplicas() |
| 5 | 滚动更新进行中 | rollingUpdatePartition() | wantReplicas() |

**`wantReplicas` 计算**:

```go
func calculateRollingUpdateReplicas(
    lwsReplicas, maxSurge, maxUnavailable, unreadyReplicas int32,
) int32 {
    burstReplicas := lwsReplicas + maxSurge
    if unreadyReplicas <= maxSurge {
        requiredSurgeReplicas := nonZeroValue(unreadyReplicas - maxUnavailable)
        return lwsReplicas + requiredSurgeReplicas
    }
    return burstReplicas
}
```

**`rollingUpdatePartition` 计算**:

```go
func rollingUpdatePartition(
    states []replicaState,
    stsReplicas, rollingStep, currentPartition int32,
) int32 {
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

    return min(partition, currentPartition)
}
```

#### 5.1.4 Server-Side Apply (SSA)

LWS 使用 Server-Side Apply 管理 Leader StatefulSet，关键点：

- **FieldManager**: `"lws"`
- **Force**: `true` — 强制获取字段所有权
- **优势**: 避免冲突、支持多控制器协作、原子性更新

```go
func (r *LeaderWorkerSetReconciler) SSAWithStatefulset(
    ctx context.Context,
    lws *leaderworkerset.LeaderWorkerSet,
    partition, replicas int32,
    revisionKey string,
) error {
    // 构造 Apply Configuration
    leaderStatefulSetApplyConfig := constructLeaderStatefulSetApplyConfiguration(...)

    // 设置 Controller Reference
    setControllerReferenceWithStatefulSet(lws, leaderStatefulSetApplyConfig, r.Scheme)

    // 转换为 Unstructured
    obj := runtime.DefaultUnstructuredConverter.ToUnstructured(leaderStatefulSetApplyConfig)
    patch := &unstructured.Unstructured{Object: obj}

    // Server-Side Apply
    return r.Patch(ctx, patch, client.Apply, &client.PatchOptions{
        FieldManager: "lws",
        Force:        ptr.To(true),
    })
}
```

#### 5.1.5 Revision 管理

LWS 使用 `ControllerRevision` 追踪模板版本：

1. **创建 Revision**: 当 LWS 创建或模板更新时
2. **比较 Revision**: 使用 `revisionutils.EqualRevision` 比较原始字节
3. **语义比较**: 使用 LRU 缓存的 `SetMatchesRevision` 避免误触发滚动更新
4. **截断 Revision**: 更新完成后清理旧 Revision

```go
// LRU 缓存避免重复计算语义相等性
const maxRevisionEqualityCacheEntries = 10_000

revisionEqualityCache *lru.Cache
```

### 5.2 Pod Reconciler

#### 5.2.1 核心职责

1. **创建 Worker StatefulSet**: 为每个 Leader Pod 创建对应的 Worker STS
2. **处理 Restart Policy**: 根据策略删除 Leader 触发组重建
3. **创建 PodGroup**: 通过 SchedulerProvider 创建 Gang 调度组
4. **设置独占放置**: 根据 Leader Pod 的拓扑设置 Worker 的 NodeSelector

#### 5.2.2 Reconcile 流程详解

```
Reconcile(ctx, req)
    │
    ├── 1. 获取 Pod
    │
    ├── 2. 获取 LWS 名称和索引
    │
    ├── 3. 获取 LeaderWorkerSet 对象
    │
    ├── 4. 处理 Restart Policy
    │   ├── 检查是否有容器重启或 Pod 删除
    │   ├── 检查是否有 Pending Pod（RecreateGroupAfterStart）
    │   └── 删除 Leader Pod 触发组重建
    │
    ├── 5. 如果是 Worker Pod，返回（仅处理 Leader）
    │
    ├── 6. 验证 Leader 注解（防止无限循环）
    │
    ├── 7. 创建 Headless Service（UniquePerReplica 模式）
    │
    ├── 8. 创建 PodGroup（如果配置了 SchedulerProvider）
    │
    ├── 9. 如果 size=1，返回（无需创建 Worker STS）
    │
    ├── 10. LeaderReady 策略：等待 Leader 就绪
    │
    ├── 11. 获取 Revision
    │
    ├── 12. 构造 Worker STS Apply Configuration
    │
    ├── 13. 设置独占放置（如果配置了 ExclusiveKey）
    │   ├── 获取 Leader Pod 的 NodeName
    │   ├── 获取 Node 的拓扑标签值
    │   └── 设置 Worker STS 的 NodeSelector
    │
    └── 14. 创建 Worker StatefulSet
```

#### 5.2.3 Worker StatefulSet 构造

```go
func constructWorkerStatefulSetApplyConfiguration(
    leaderPod corev1.Pod,
    lws leaderworkerset.LeaderWorkerSet,
    currentRevision *appsv1.ControllerRevision,
) (*appsapplyv1.StatefulSetApplyConfiguration, error) {
    // 从 Revision 恢复 LWS 模板
    currentLws := revisionutils.ApplyRevision(&lws, currentRevision)

    // 使用 WorkerTemplate
    podTemplateSpec := currentLws.Spec.LeaderWorkerTemplate.WorkerTemplate

    // 构造 StatefulSet
    statefulSetConfig := appsapplyv1.StatefulSet(leaderPod.Name, leaderPod.Namespace).
        WithSpec(appsapplyv1.StatefulSetSpec().
            WithServiceName(serviceName).
            WithReplicas(*lws.Spec.LeaderWorkerTemplate.Size - 1).  // Worker 数量 = Size - 1
            WithPodManagementPolicy(appsv1.ParallelPodManagement).  // 并行创建
            WithOrdinals(appsapplyv1.StatefulSetOrdinals().WithStart(1)).  // 从 1 开始
            WithSelector(...)).
        WithLabels(...)

    return statefulSetConfig, nil
}
```

#### 5.2.4 Restart Policy 详解

| 策略 | 行为 |
|------|------|
| `RecreateGroupOnPodRestart` | 任意 Pod 重启或容器重启时，删除 Leader Pod 触发整个组重建 |
| `RecreateGroupAfterStart` | 类似上者，但仅在组内所有 Pod 都已启动（非 Pending）后才触发 |
| `None` | 仅重启失败的 Pod，不影响其他 Pod |

#### 5.2.5 独占放置 (Exclusive Placement)

当 LWS 配置了 `ExclusiveKeyAnnotationKey` 时：

1. Leader Pod 被调度到某个 Node
2. Pod Reconciler 读取该 Node 的拓扑标签值
3. 将该拓扑值设置为 Worker STS 的 NodeSelector
4. 确保 Leader 和 Workers 在同一拓扑域内

```go
func (r *PodReconciler) setNodeSelectorForWorkerPods(
    ctx context.Context,
    pod *corev1.Pod,
    sts *appsapplyv1.StatefulSetApplyConfiguration,
    topologyKey string,
) error {
    // 获取 Leader Pod 所在 Node
    node := getNode(pod.Spec.NodeName)

    // 获取拓扑值
    topologyValue := node.Labels[topologyKey]

    // 设置 Worker STS 的 NodeSelector
    sts.Spec.Template.Spec.WithNodeSelector(map[string]string{
        topologyKey: topologyValue,
    })

    return nil
}
```

### 5.3 DisaggregatedSet Reconciler (Stub)

主项目中的 DS 控制器是一个最小化的 Stub 实现：

```go
func (r *DisaggregatedSetReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := ctrl.LoggerFrom(ctx)
    log.Info("Reconciling DisaggregatedSet")
    return ctrl.Result{}, nil
}
```

完整的 DS 实现位于 `disaggregatedset/` 子项目中。

---

## 6. Webhook 机制

### 6.1 LeaderWorkerSet Webhook

#### 6.1.1 Defaulter

```go
func (r *LeaderWorkerSetWebhook) Default(ctx context.Context, obj runtime.Object) error {
    lws := obj.(*leaderworkerset.LeaderWorkerSet)

    // 默认 RestartPolicy
    if lws.Spec.LeaderWorkerTemplate.RestartPolicy == "" {
        lws.Spec.LeaderWorkerTemplate.RestartPolicy = leaderworkerset.RecreateGroupOnPodRestart
    }

    // 默认 RolloutStrategy
    if lws.Spec.RolloutStrategy.Type == "" {
        lws.Spec.RolloutStrategy.Type = leaderworkerset.RollingUpdateStrategyType
    }
    if lws.Spec.RolloutStrategy.RollingUpdateConfiguration == nil {
        lws.Spec.RolloutStrategy.RollingUpdateConfiguration = &leaderworkerset.RollingUpdateConfiguration{
            MaxUnavailable: intstr.FromInt32(1),
            MaxSurge:       intstr.FromInt32(0),
        }
    }

    // 默认 NetworkConfig
    if lws.Spec.NetworkConfig == nil {
        lws.Spec.NetworkConfig = &leaderworkerset.NetworkConfig{
            SubdomainPolicy: ptr.To(leaderworkerset.SubdomainShared),
        }
    }

    return nil
}
```

#### 6.1.2 Validator

校验规则：

| 字段 | 规则 |
|------|------|
| Replicas | ≥ 0 |
| Size | ≥ 1 |
| MaxUnavailable | 不能与 MaxSurge 同时为 0 |
| MaxSurge | ≥ 0 |
| Partition | 0 ≤ Partition ≤ Replicas |
| SubGroupSize | 必须整除 Size 或 Size-1 |
| SubGroupSize | 更新时不可变 |

### 6.2 Pod Webhook

#### 6.2.1 Defaulter

```go
func (r *PodWebhook) Default(ctx context.Context, obj runtime.Object) error {
    pod := obj.(*corev1.Pod)

    // 注入标签
    pod.Labels[GroupIndexLabelKey] = ...
    pod.Labels[WorkerIndexLabelKey] = ...
    pod.Labels[SubGroupIndexLabelKey] = ...

    // 设置独占放置亲和性
    if exclusiveKey != "" {
        setExclusiveAffinity(pod, exclusiveKey)
    }

    // 注入调度器 PodGroup 元数据
    if r.SchedulerProvider != nil {
        r.SchedulerProvider.InjectPodGroupMetadata(pod)
    }

    // 注入 TPU 环境变量
    acceleratorutils.AddTPUAnnotations(...)

    // 注入 LWS 环境变量
    injectLWSEnvironmentVariables(pod)

    return nil
}
```

#### 6.2.2 注入的环境变量

| 环境变量 | 值 | 注入位置 |
|----------|------|----------|
| `LWS_LEADER_ADDRESS` | `{lwsName}-{groupIndex}.{serviceName}` | 所有容器 |
| `LWS_GROUP_SIZE` | `{size}` | 所有容器 |
| `LWS_WORKER_INDEX` | `{workerIndex}` | 所有容器 |

### 6.3 DisaggregatedSet Webhook

仅包含 Validator：

- 验证 `RolloutStrategy.Type` 必须为 `RollingUpdate`（或空）
- 验证 `Partition` 字段不允许设置

---

## 7. Volcano 与 Gang 调度

### 7.1 Gang 调度概述

Gang 调度是一种确保一组相关 Pod 同时被调度的策略。在 LWS 中，这意味着一个 Leader-Worker 组的所有 Pod 要么全部被调度，要么全部不被调度，避免资源浪费。

### 7.2 SchedulerProvider 接口

```go
// pkg/schedulerprovider/interface.go

type SchedulerProvider interface {
    // CreatePodGroupIfNotExists 创建 PodGroup（如果不存在）
    CreatePodGroupIfNotExists(
        ctx context.Context,
        lws *leaderworkerset.LeaderWorkerSet,
        leaderPod *corev1.Pod,
    ) error

    // InjectPodGroupMetadata 注入 PodGroup 元数据到 Pod
    InjectPodGroupMetadata(pod *corev1.Pod) error
}

type ProviderType string

const (
    Volcano ProviderType = "volcano"
)

var SupportedSchedulerProviders = sets.New(Volcano)

func NewSchedulerProvider(providerType ProviderType, client client.Client) (SchedulerProvider, error) {
    switch providerType {
    case Volcano:
        return NewVolcanoProvider(client), nil
    default:
        return nil, fmt.Errorf("unsupported scheduler provider: %s", providerType)
    }
}
```

### 7.3 VolcanoProvider 实现

#### 7.3.1 PodGroup 创建

```go
// pkg/schedulerprovider/volcano_provider.go

func (v *VolcanoProvider) CreatePodGroupIfNotExists(
    ctx context.Context,
    lws *leaderworkerset.LeaderWorkerSet,
    leaderPod *corev1.Pod,
) error {
    pgName := leaderPod.Annotations[volcanov1beta1.KubeGroupNameAnnotationKey]

    // 检查 PodGroup 是否已存在
    if err := v.client.Get(ctx, ..., &pg); err != nil {
        if !apierrors.IsNotFound(err) {
            return err
        }

        // 计算最小资源
        minResources := utils.CalculatePGMinResources(lws)

        // 创建 PodGroup
        pg = volcanov1beta1.PodGroup{
            ObjectMeta: metav1.ObjectMeta{
                Name:      pgName,
                Namespace: lws.Namespace,
                Labels: map[string]string{
                    SetNameLabelKey:    lws.Name,
                    GroupIndexLabelKey: leaderPod.Labels[GroupIndexLabelKey],
                    RevisionKey:        leaderPod.Labels[RevisionKey],
                },
                Annotations: inheritVolcanoAnnotations(lws),
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

        // 设置 Queue
        if queueName, ok := lws.Annotations[volcanov1beta1.QueueNameAnnotationKey]; ok {
            pg.Spec.Queue = queueName
        }

        // 设置 OwnerReference
        ctrl.SetControllerReference(leaderPod, &pg, v.client.Scheme())

        // 创建 PodGroup
        return v.client.Create(ctx, &pg)
    }

    return nil
}
```

#### 7.3.2 PodGroup 元数据注入

```go
func (v *VolcanoProvider) InjectPodGroupMetadata(pod *corev1.Pod) error {
    lwsName := pod.Labels[SetNameLabelKey]
    groupIndex := pod.Labels[GroupIndexLabelKey]
    revision := pod.Labels[RevisionKey]

    // 设置 PodGroup 名称注解
    pod.Annotations[volcanov1beta1.KubeGroupNameAnnotationKey] =
        GetPodGroupName(lwsName, groupIndex, revision)

    return nil
}
```

#### 7.3.3 PodGroup 命名规则

```
PodGroup 名称格式: {lwsName}-{groupIndex}-{revisionHash}

示例: my-llm-0-a1b2c3d4
```

#### 7.3.4 Volcano 注解继承

LWS 上以 `volcano.sh/` 为前缀的注解会被继承到 PodGroup：

```go
func inheritVolcanoAnnotations(lws *leaderworkerset.LeaderWorkerSet) map[string]string {
    res := map[string]string{}
    for k, v := range lws.Annotations {
        if strings.HasPrefix(k, "volcano.sh/") {
            res[k] = v
        }
    }
    return res
}
```

### 7.4 启用 Gang 调度

#### 7.4.1 配置方式

**方式 1: Helm values**

```yaml
gangSchedulingManagement:
  schedulerProvider: volcano
```

**方式 2: Kustomize**

在 `config/default/kustomization.yaml` 中取消注释：

```yaml
components:
  - ../components/volcano
```

**方式 3: Configuration CR**

```yaml
apiVersion: config.lws.x-k8s.io/v1alpha1
kind: Configuration
gangSchedulingManagement:
  schedulerProvider: volcano
```

#### 7.4.2 RBAC 配置

Volcano 组件会添加以下 RBAC 权限：

```yaml
apiGroups: ["scheduling.volcano.sh"]
resources: ["podgroups"]
verbs: ["create", "get", "list", "watch"]
```

#### 7.4.3 用户侧配置

在 LWS 的 Pod 模板中指定 Volcano 调度器：

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: my-llm
  annotations:
    volcano.sh/queue-name: "my-queue"  # 可选：指定队列
spec:
  leaderWorkerTemplate:
    workerTemplate:
      spec:
        schedulerName: volcano  # 指定 Volcano 调度器
        containers:
          - name: worker
            resources:
              requests:
                nvidia.com/gpu: "8"
```

### 7.5 Gang 调度与启动策略

| 启动策略 | MinMember | MinResources | 说明 |
|----------|-----------|--------------|------|
| `LeaderCreated` | Size | Leader + (Size-1) * Worker | 所有 Pod 必须同时调度 |
| `LeaderReady` | 1 | Leader + (Size-1) * Worker | 先调度 Leader，再调度 Workers |

**LeaderReady 策略的特殊处理**:

- `MinMember=1`: 允许 Leader 单独被调度
- `MinResources` 仍然包含所有 Pod 的资源：如果集群资源不足以调度所有 Worker，仅调度 Leader 也是无意义的

### 7.6 PodGroup 生命周期

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
    │
    └── 如果满足，调度所有 Pods
        │
        ▼
    组内所有 Pods 运行
```

**PodGroup 清理**:

- PodGroup 通过 OwnerReference 绑定到 Leader Pod
- 当 Leader Pod 被删除时，PodGroup 自动被 GC
- LWS 删除时，所有 Leader Pod 被删除，PodGroup 随之清理

### 7.7 E2E 测试

测试文件: `test/e2e/e2e_gang_scheduling_test.go`

测试场景：
1. PodGroup 创建（LeaderCreated 策略）
2. PodGroup 创建（LeaderReady 策略）
3. LWS 删除时 PodGroup 清理
4. LWS 扩缩容时 PodGroup 重建
5. LWS 滚动更新时 PodGroup 重建

测试条件：`SCHEDULER_PROVIDER=volcano`

---

## 8. PD 分离 (DisaggregatedSet)

### 8.1 概述

PD 分离（Prefill-Decode Disaggregation）是 LLM 推理的一种优化架构，将推理过程分为两个阶段：

- **Prefill 阶段**: 处理输入 Token，计算 KV Cache（计算密集型）
- **Decode 阶段**: 生成输出 Token（内存密集型）

通过分离这两个阶段，可以：
- 独立扩缩容 Prefill 和 Decode 节点
- 使用不同类型的 GPU（如 Prefill 用 A100，Decode 用 H100）
- 优化资源利用率

### 8.2 DisaggregatedSet 架构

```
DisaggregatedSet: my-llm-disagg
    │
    ├── Role "prefill"
    │   └── LeaderWorkerSet: my-llm-disagg-{revision}-prefill
    │       ├── Leader Pod (GPU x8)
    │       └── Worker Pods (GPU x8)
    │
    └── Role "decode"
        └── LeaderWorkerSet: my-llm-disagg-{revision}-decode
            ├── Leader Pod (GPU x2)
            └── Worker Pods (GPU x2)
```

### 8.3 独立子项目架构

DisaggregatedSet 的完整实现位于 `disaggregatedset/` 子项目中，具有独立的 `go.mod`。

#### 8.3.1 控制器组件

```
disaggregatedset/internal/controller/
├── disaggregatedset_controller.go  # 主调谐器
├── planner.go                      # N 维滚动更新规划器
├── executor.go                     # 执行器
├── workload_manager.go             # LWS 工作负载管理
├── service_manager.go              # Headless Service 管理
└── utils.go                        # 工具函数
```

#### 8.3.2 Planner — N 维滚动更新算法

Planner 是 DisaggregatedSet 最复杂的组件，负责在多个角色之间协调滚动更新。

**核心算法**:

```go
// 线性插值函数
func newAtStep(step, target, totalSteps int) int {
    return int(math.Ceil(float64(step) * float64(target) / float64(totalSteps)))
}

func oldAtStep(step, source, totalSteps int) int {
    return source - int(math.Floor(float64(step)*float64(source)/float64(totalSteps)))
}
```

**算法特点**:

1. **无状态**: 从观察到的副本数计算步骤，不需要存储中间状态
2. **线性缩放**: 每步变化量与总步数成比例
3. **Surge 约束**: `old + new <= target + maxSurge`
4. **缩放方向**:
   - Scale-up: 使用所有角色的最小步数
   - Scale-down: 使用所有角色的最大步数

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

#### 8.3.3 Executor — 执行器

Executor 负责执行 Planner 生成的计划：

```go
func (e *Executor) Execute(ctx context.Context, plan *Plan) error {
    // 检测角色变化（新增/删除）
    roleChanges := detectRoleChanges(plan)

    // 执行每一步
    for _, step := range plan.Steps {
        // 更新每个角色的 LWS 副本数
        for _, role := range step.Roles {
            e.workloadManager.UpdateReplicas(ctx, role.Name, role.Replicas)
        }

        // 等待稳定
        e.waitForStability(ctx)
    }

    return nil
}
```

#### 8.3.4 WorkloadManager — 工作负载管理

WorkloadManager 管理 LeaderWorkerSet 的生命周期：

```go
type WorkloadManager struct {
    client client.Client
}

// 创建 LWS
func (m *WorkloadManager) Create(ctx context.Context, ds *DisaggregatedSet, role DisaggregatedRoleSpec, revision string) error {
    lws := &LeaderWorkerSet{
        ObjectMeta: metav1.ObjectMeta{
            Name:      generateLWSName(ds.Name, revision, role.Name),
            Namespace: ds.Namespace,
            Labels:    generateLabels(ds, role, revision),
            Annotations: map[string]string{
                "initial-replicas": strconv.Itoa(int(*role.Spec.Replicas)),
            },
        },
        Spec: role.Spec,
    }

    return m.client.Create(ctx, lws)
}

// 更新副本数
func (m *WorkloadManager) UpdateReplicas(ctx context.Context, lwsName string, replicas int32) error {
    lws := &LeaderWorkerSet{}
    if err := m.client.Get(ctx, ..., lws); err != nil {
        return err
    }

    lws.Spec.Replicas = &replicas
    return m.client.Update(ctx, lws)
}
```

**命名规则**:

```
LWS 名称格式: {baseName}-{revision}-{role}

示例: my-llm-disagg-a1b2c3d4-prefill
```

#### 8.3.5 ServiceManager — 服务管理

ServiceManager 创建 Headless Service 用于角色间通信：

```go
func (m *ServiceManager) Reconcile(ctx context.Context, ds *DisaggregatedSet, revision string) error {
    // 检查所有角色是否都有就绪副本
    allReady := true
    for _, status := range ds.Status.RoleStatuses {
        if status.ReadyReplicas == 0 {
            allReady = false
            break
        }
    }

    // 创建服务（仅当所有角色就绪）
    if allReady {
        for _, role := range ds.Spec.Roles {
            serviceName := fmt.Sprintf("%s-%s-%s-prv", ds.Name, revision, role.Name)
            m.createServiceIfNotExists(ctx, serviceName, ds, role, revision)
        }
    }

    // 清理旧 Revision 的服务（仅当旧 Revision 完全清空）
    m.cleanupOldServices(ctx, ds, revision)

    return nil
}
```

**服务命名规则**:

```
Service 名称格式: {baseName}-{revision}-{role}-prv

示例: my-llm-disagg-a1b2c3d4-prefill-prv
```

### 8.4 Revision 管理

DisaggregatedSet 使用 SHA-256 计算所有角色模板的哈希值作为 Revision：

```go
func computeRevision(ds *DisaggregatedSet) (string, error) {
    // 序列化所有角色的 Spec
    data, err := json.Marshal(ds.Spec.Roles)

    // 计算 SHA-256
    hash := sha256.Sum256(data)
    return hex.EncodeToString(hash[:])[:8], nil  // 取前 8 位
}
```

### 8.5 示例配置

```yaml
apiVersion: disaggregatedset.x-k8s.io/v1
kind: DisaggregatedSet
metadata:
  name: my-llm-disagg
spec:
  roles:
    - name: prefill
      spec:
        replicas: 2
        leaderWorkerTemplate:
          size: 1
          workerTemplate:
            spec:
              containers:
                - name: prefill
                  image: vllm/vllm-openai:latest
                  resources:
                    limits:
                      nvidia.com/gpu: "8"
                  args:
                    - "--tensor-parallel-size=8"
                    - "--role=prefill"

    - name: decode
      spec:
        replicas: 4
        leaderWorkerTemplate:
          size: 1
          workerTemplate:
            spec:
              containers:
                - name: decode
                  image: vllm/vllm-openai:latest
                  resources:
                    limits:
                      nvidia.com/gpu: "2"
                  args:
                    - "--tensor-parallel-size=2"
                    - "--role=decode"
```

---

## 9. 昇腾卡相关分析

### 9.1 现状分析

经过对整个代码库的全面搜索，**LWS 项目中没有任何昇腾 (Ascend) NPU 相关的代码或配置**。

搜索范围包括：
- 所有 Go 源代码
- 所有 YAML 配置文件
- 所有 Markdown 文档
- Helm Chart 模板
- KEP 文档

搜索关键词：
- `ascend`、`Ascend`
- `npu`、`NPU`
- `昇腾`
- `davinci`
- `huawei`
- `ascend-910`

### 9.2 现有加速器支持

LWS 目前支持两种加速器：

#### 9.2.1 Google TPU

**代码位置**: `pkg/utils/accelerators/tpu.go`

**功能**:
- 注入 TPU 环境变量
- 子组感知的 TPU 变量配置
- TPU 注解传播

**注入的环境变量**:
| 环境变量 | 用途 |
|----------|------|
| `TPU_WORKER_HOSTNAMES` | TPU Worker 主机名列表 |
| `TPU_PROCESS_ADDRESSES` | TPU 进程地址列表 |
| `TPU_WORKER_ID` | 当前 Worker ID |
| `TPU_NAME` | TPU 资源名称 |

**示例配置**: `config/samples/leaderworkerset_tpu.yaml`

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: tpu-lws
spec:
  replicas: 2
  leaderWorkerTemplate:
    size: 4
    workerTemplate:
      spec:
        nodeSelector:
          cloud.google.com/gke-tpu-topology: 2x2x2
          cloud.google.com/gke-tpu-accelerator: tpu-v4-podslice
        containers:
          - name: worker
            resources:
              limits:
                google.com/tpu: 4
```

#### 9.2.2 NVIDIA GPU

**支持方式**: 通过标准的 `nvidia.com/gpu` 资源请求

**示例配置**: `docs/examples/vllm/GPU/lws.yaml`

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: vllm-gpu
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2
    leaderTemplate:
      spec:
        containers:
          - name: vllm
            resources:
              limits:
                nvidia.com/gpu: "8"
            args:
              - "--tensor-parallel-size=8"
              - "--pipeline-parallel-size=2"
    workerTemplate:
      spec:
        containers:
          - name: vllm
            resources:
              limits:
                nvidia.com/gpu: "8"
```

### 9.3 昇腾卡适配分析

如果要适配昇腾卡，需要考虑以下方面：

#### 9.3.1 资源请求

昇腾 NPU 使用 `huawei.com/ascend-910` 或类似的资源名称。LWS 本身不关心具体的资源类型，只需要在 Pod 模板中正确指定即可：

```yaml
containers:
  - name: worker
    resources:
      limits:
        huawei.com/ascend-910: "8"
```

#### 9.3.2 环境变量注入

类似 TPU 的环境变量注入，可能需要为昇腾卡添加：
- NPU 设备拓扑信息
- HCCL（Huawei Collective Communication Library）配置
- 节点间通信配置

#### 9.3.3 拓扑感知调度

昇腾集群的拓扑结构（如 Pod、节点、交换机）需要映射到 Kubernetes 的拓扑标签：
- `topology.kubernetes.io/zone`
- 自定义拓扑标签

#### 9.3.4 Gang 调度

Volcano 对昇腾卡的支持需要确保：
- PodGroup 的 MinResources 正确计算 `huawei.com/ascend-910` 资源
- 调度器能正确感知昇腾卡的拓扑

### 9.4 适配建议

1. **创建 Accelerator Utility**: 类似 `pkg/utils/accelerators/tpu.go`，创建 `ascend.go`
2. **环境变量注入**: 在 Pod Webhook 中注入 HCCL 相关环境变量
3. **拓扑标签**: 定义昇腾拓扑标签并集成到 Exclusive Placement
4. **Volcano 集成**: 确保 Volcano 能正确调度昇腾卡资源
5. **示例配置**: 创建昇腾卡的示例 YAML

---

## 10. 关键优化技术总结

### 10.1 Server-Side Apply (SSA)

**问题**: 多个控制器或工具可能同时修改同一资源，导致冲突。

**解决方案**: 使用 SSA，每个控制器声明自己拥有的字段：

```go
r.Patch(ctx, patch, client.Apply, &client.PatchOptions{
    FieldManager: "lws",
    Force:        true,  // 强制获取所有权
})
```

**优势**:
- 原子性更新
- 自动冲突检测和解决
- 支持多控制器协作

### 10.2 ControllerRevision 版本管理

**问题**: 需要精确追踪模板变更，支持回滚和灰度发布。

**解决方案**: 使用 Kubernetes 的 ControllerRevision 存储模板版本：

```go
// 创建 Revision
revision := &appsv1.ControllerRevision{
    ObjectMeta: metav1.ObjectMeta{
        Name:      revisionName(lws, hash),
        Namespace: lws.Namespace,
        Labels: map[string]string{
            RevisionKey: hash,
            SetNameLabelKey: lws.Name,
        },
    },
    Data:     runtime.RawExtension{Object: lws},
    Revision: revisionNumber,
}
```

**优化**: 使用 LRU 缓存避免重复计算语义相等性：

```go
const maxRevisionEqualityCacheEntries = 10_000

// 如果缓存命中，跳过详细的语义比较
if cached, ok := r.revisionEqualityCache.Get(key); ok {
    return cached.(bool)
}
```

### 10.3 并行 Pod 管理

**问题**: 顺序创建 Pod 导致启动缓慢。

**解决方案**: StatefulSet 使用 `ParallelPodManagement` 策略：

```go
WithPodManagementPolicy(appsv1.ParallelPodManagement)
```

**Worker STS 使用 Ordinals 从 1 开始**:

```go
WithOrdinals(appsapplyv1.StatefulSetOrdinals().WithStart(1))
```

### 10.4 滚动更新优化

**问题**: 传统滚动更新可能导致大量 Pod 同时不可用。

**解决方案**: 使用 maxSurge + maxUnavailable 组合策略：

```go
// 计算 StatefulSet 的 MaxUnavailable
stsMaxUnavailable := lwsMaxUnavailable + lwsMaxSurge

// 计算实际副本数
func calculateRollingUpdateReplicas(lwsReplicas, maxSurge, maxUnavailable, unreadyReplicas int32) int32 {
    if unreadyReplicas <= maxSurge {
        requiredSurge := nonZeroValue(unreadyReplicas - maxUnavailable)
        return lwsReplicas + requiredSurge
    }
    return lwsReplicas + maxSurge
}
```

### 10.5 拓扑感知调度

**问题**: 分布式推理需要 Pod 在同一拓扑域内（如同一机架或同一节点池）。

**解决方案**: 通过注解配置独占拓扑：

```yaml
annotations:
  leaderworkerset.sigs.k8s.io/exclusive-topology: cloud.google.com/gke-nodepool
```

**实现**: Pod Webhook 根据 Leader Pod 的 Node 设置 Worker STS 的 NodeSelector。

### 10.6 Gang 调度

**问题**: 部分 Pod 被调度但资源不足，导致资源浪费。

**解决方案**: 通过 Volcano PodGroup 实现组调度：

- 每个 Leader-Worker 组创建一个 PodGroup
- PodGroup 的 MinMember 确保所有 Pod 同时被调度
- PodGroup 的 MinResources 预留整个组的资源

### 10.7 N 维滚动更新 (DisaggregatedSet)

**问题**: 多角色之间的滚动更新需要协调，避免所有角色同时更新。

**解决方案**: 使用线性插值算法：

```go
// 每步只改变一个维度
func planStep(current, target, totalSteps []int) []int {
    step := make([]int, len(current))
    for i := range current {
        if current[i] < target[i] {
            step[i] = min(current[i]+1, target[i])
        } else if current[i] > target[i] {
            step[i] = max(current[i]-1, target[i])
        }
    }
    return step
}
```

### 10.8 状态条件管理

**问题**: 需要清晰地表达 LWS 的当前状态。

**解决方案**: 使用 Kubernetes 标准条件类型：

```go
// 互斥条件：Available 和 Progressing 不能同时为 True
func exclusiveConditionTypes(c1, c2 metav1.Condition) bool {
    if (c1.Type == "Available" && c2.Type == "Progressing") ||
       (c1.Type == "Progressing" && c2.Type == "Available") {
        return true
    }
    // ...
}
```

### 10.9 内置证书管理

**问题**: Webhook 需要 TLS 证书，外部依赖 cert-manager 增加复杂度。

**解决方案**: 使用 `cert-controller` 库实现内置证书轮换：

```go
// 自签名 CA
cert := &x509.Certificate{
    SerialNumber: big.NewInt(1),
    Subject:      pkix.Name{CommonName: "lws-webhook"},
    NotBefore:    time.Now(),
    NotAfter:     time.Now().Add(365 * 24 * time.Hour),
    KeyUsage:     x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
    IsCA:         true,
}
```

### 10.10 HPA 集成

**问题**: 需要根据负载自动扩缩容 LWS。

**解决方案**: 通过 scale 子资源支持 HPA：

```go
//+kubebuilder:subresource:scale:specpath=.spec.replicas,statuspath=.status.replicas,selectorpath=.status.hpaPodSelector
```

**HPAPodSelector**: 只选择 Leader Pod，避免重复计算：

```go
lws.Status.HPAPodSelector = labels.Set{
    SetNameLabelKey:     lws.Name,
    WorkerIndexLabelKey: "0",  // 只选择 Leader
}.String()
```

---

## 11. 部署与构建系统

### 11.1 构建系统

#### 11.1.1 Makefile 关键目标

| 目标 | 作用 |
|------|------|
| `manifests` | 生成 CRD、RBAC、Webhook 清单 |
| `generate` | 生成 DeepCopy 和 client-go 代码 |
| `build` | 构建二进制文件 |
| `image-build` | 构建多平台 Docker 镜像 |
| `deploy`/`undeploy` | Kustomize 部署/卸载 |
| `install`/`uninstall` | 仅安装/卸载 CRD |
| `test` | 单元测试 |
| `test-integration` | 集成测试 |
| `test-e2e` | E2E 测试 |
| `test-e2e-gang-scheduling-volcano` | Gang 调度 E2E 测试 |
| `helm-chart-push` | 推送 Helm Chart |
| `artifacts` | 构建发布产物 |

#### 11.1.2 Dockerfile

```dockerfile
# 多阶段构建
FROM golang:1.26 AS builder
WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o manager cmd/main.go

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /workspace/manager .
USER 65532:65532
ENTRYPOINT ["/manager"]
```

#### 11.1.3 支持的平台

```makefile
PLATFORMS = linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
```

### 11.2 部署方式

#### 11.2.1 kubectl + Kustomize

```bash
# 安装 CRD
make install

# 部署控制器
make deploy

# 卸载
make undeploy
make uninstall
```

#### 11.2.2 Helm

```bash
# 安装
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

### 11.3 版本管理

| 组件 | 版本 |
|------|------|
| LWS | v0.8.0 |
| Kubernetes | v1.36.x |
| Go | 1.26 |
| controller-runtime | v0.24.1 |
| Volcano | v1.12.1 |
| cert-manager | v1.17.0 |

---

## 12. 测试体系

### 12.1 测试层次

```
测试金字塔
    │
    ├── E2E 测试 (test/e2e/)
    │   ├── 端到端功能验证
    │   ├── 需要 Kind 集群
    │   └── 测试时间较长
    │
    ├── 集成测试 (test/integration/)
    │   ├── 控制器集成测试
    │   ├── Webhook 集成测试
    │   └── 使用 envtest
    │
    └── 单元测试 (*_test.go)
        ├── 与源代码同目录
        ├── 快速执行
        └── 覆盖率高
```

### 12.2 E2E 测试

#### 12.2.1 测试文件

| 文件 | 测试内容 |
|------|----------|
| `e2e_test.go` | LWS 核心功能 |
| `e2e_gang_scheduling_test.go` | Gang 调度功能 |

#### 12.2.2 Gang 调度 E2E 测试

```go
// 测试 PodGroup 创建
It("should create PodGroup for each replica", func() {
    // 创建 LWS with volcano scheduler
    lws := createLWSWithVolcano()
    waitForLWSReady(lws)

    // 验证 PodGroup 存在
    for i := 0; i < int(*lws.Spec.Replicas); i++ {
        pgName := fmt.Sprintf("%s-%d-%s", lws.Name, i, revisionHash)
        pg := getPodGroup(pgName)
        Expect(pg.Spec.MinMember).To(Equal(*lws.Spec.LeaderWorkerTemplate.Size))
    }
})

// 测试 PodGroup 清理
It("should cleanup PodGroup when LWS is deleted", func() {
    // 删除 LWS
    deleteLWS(lws)

    // 验证 PodGroup 被清理
    Eventually(func() bool {
        return podGroupsDeleted(lws)
    }).Should(BeTrue())
})
```

### 12.3 集成测试

使用 controller-runtime 的 `envtest` 框架：

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

### 12.4 测试工具

#### 12.4.1 测试辅助函数 (`test/testutils/`)

```go
// 创建 LWS
func CreateLeaderWorkerSet(ctx context.Context, lws *leaderworkerset.LeaderWorkerSet, namespace string)

// 等待 LWS 就绪
func WaitForLeaderWorkerSetReady(ctx context.Context, lws *leaderworkerset.LeaderWorkerSet)

// 验证条件
func ExpectCondition(lws *leaderworkerset.LeaderWorkerSet, conditionType string, status metav1.ConditionStatus)
```

#### 12.4.2 测试包装器 (`test/wrappers/`)

```go
// Builder 模式构造测试 LWS
lws := wrappers.NewLeaderWorkerSet("test-lws", namespace).
    Replicas(3).
    Size(4).
    RestartPolicy(leaderworkerset.RecreateGroupOnPodRestart).
    RolloutStrategy(leaderworkerset.RollingUpdateStrategyType, 1, 0).
    Obj()
```

---

## 13. KEP 特性提案索引

### 13.1 KEP 列表

| KEP | 名称 | 状态 | 描述 |
|-----|------|------|------|
| 115 | Subgroup Support | Implemented | 在 LWS 组内创建子组 |
| 135 | Startup Policy | Implemented | LeaderCreated vs LeaderReady 启动策略 |
| 173 | Headless Service Per Replica | Implemented | UniquePerReplica 子域策略 |
| 238 | Controller Revision | Implemented | 使用 ControllerRevision 进行模板版本管理 |
| 257 | Subgroup Leader Only | Implemented | LeaderExcluded 子组策略 |
| 407 | Gang Scheduling | Implemented | Volcano PodGroup 集成 |
| 511 | Partition Update | Implemented | 基于 Partition 的滚动更新 |
| 552 | Worker Resizing | Implemented | Worker 扩缩容支持 |
| 622 | Volume Claim Templates | Implemented | PVC 模板支持 |
| 766 | DisaggregatedSet | Implemented | 分离式推理编排 |

### 13.2 关键 KEP 详解

#### 13.2.1 KEP-407: Gang Scheduling

**目标**: 确保 LWS 组内所有 Pod 同时被调度。

**设计**:
- 使用 `SchedulerProvider` 接口支持多种调度器
- 当前仅支持 Volcano
- PodGroup 生命周期绑定到 Leader Pod

**接口**:

```go
type SchedulerProvider interface {
    CreatePodGroupIfNotExists(ctx context.Context, lws *LeaderWorkerSet, leaderPod *Pod) error
    InjectPodGroupMetadata(pod *Pod) error
}
```

#### 13.2.2 KEP-766: DisaggregatedSet

**目标**: 支持 Prefill-Decode 分离的推理架构。

**设计**:
- 2-10 个角色，每个角色对应一个 LWS
- N 维滚动更新算法
- 独立的 Headless Service 管理

**核心算法**: 线性插值实现平滑的多角色扩缩容。

#### 13.2.3 KEP-115: Subgroup Support

**目标**: 在 LWS 组内创建逻辑子组。

**两种策略**:
- `LeaderWorker`: Leader 包含在第一个子组中
- `LeaderExcluded`: Leader 不属于任何子组

**用途**: 支持更细粒度的拓扑感知和调度。

---

## 附录 A: 关键配置参数速查

### A.1 LeaderWorkerSet 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `spec.replicas` | int32 | 1 | Leader-Worker 组数量 |
| `spec.leaderWorkerTemplate.size` | int32 | 1 | 每组 Pod 总数 |
| `spec.leaderWorkerTemplate.restartPolicy` | string | RecreateGroupOnPodRestart | 重启策略 |
| `spec.rolloutStrategy.type` | string | RollingUpdate | 更新策略 |
| `spec.rolloutStrategy.rollingUpdateConfiguration.partition` | int32 | 0 | 分区点 |
| `spec.rolloutStrategy.rollingUpdateConfiguration.maxUnavailable` | IntOrString | 1 | 最大不可用数 |
| `spec.rolloutStrategy.rollingUpdateConfiguration.maxSurge` | IntOrString | 0 | 最大超出数 |
| `spec.startupPolicy` | string | LeaderCreated | 启动策略 |
| `spec.networkConfig.subdomainPolicy` | string | Shared | 子域策略 |

### A.2 Configuration 参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `leaderElect` | bool | true | 启用 Leader Election |
| `internalCertManagement.enable` | bool | true | 启用内置证书管理 |
| `gangSchedulingManagement.schedulerProvider` | string | "" | Gang 调度器（volcano） |

### A.3 Helm Values

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `enablePrometheus` | bool | false | 启用 Prometheus 监控 |
| `enableCertManager` | bool | false | 使用 cert-manager |
| `image.manager.repository` | string | registry.k8s.io/lws/lws | 镜像仓库 |
| `image.manager.tag` | string | main | 镜像标签 |
| `gangSchedulingManagement` | object | {} | Gang 调度配置 |

---

## 附录 B: 常见问题

### B.1 如何启用 Volcano Gang 调度？

1. 安装 Volcano 调度器
2. 在 Helm values 中设置 `gangSchedulingManagement.schedulerProvider: volcano`
3. 在 Pod 模板中设置 `schedulerName: volcano`

### B.2 如何实现独占拓扑？

在 LWS 上添加注解：

```yaml
annotations:
  leaderworkerset.sigs.k8s.io/exclusive-topology: topology-key
```

### B.3 如何实现 PD 分离？

使用 DisaggregatedSet CRD，定义 prefill 和 decode 两个角色，每个角色配置不同的 GPU 资源和参数。

### B.4 如何扩展加速器支持？

1. 创建 `pkg/utils/accelerators/{accelerator}.go`
2. 在 Pod Webhook 中注入相关环境变量
3. 定义拓扑标签并集成到 Exclusive Placement
4. 确保 Volcano 正确计算资源

---

*文档生成完成。如有疑问，请参考项目源代码或 KEP 文档。*
