# LeaderWorkerSet Partition 设置指南

## Partition 的正确使用方式

### 基本规则
- **Partition 必须在 [0, replicas] 范围内**
- Partition = 0：更新所有 Pod（完全更新）
- Partition = replicas：不更新任何 Pod（暂停更新）
- 0 < Partition < replicas：部分更新

### 常见使用场景

#### 1. 初始部署（推荐）
```yaml
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 0  # 更新所有 Pod
    maxUnavailable: 2
    maxSurge: 3
replicas: 6
```

#### 2. 金丝雀发布
```yaml
# 第一步：只更新最后一个 Pod
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 5  # replicas - 1
    maxUnavailable: 1
    maxSurge: 0
replicas: 6

# 第二步：验证后，更新更多 Pod
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 3  # 更新后 3 个 Pod
    maxUnavailable: 1
    maxSurge: 0
replicas: 6

# 第三步：完全更新
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 0  # 更新所有 Pod
    maxUnavailable: 2
    maxSurge: 0
replicas: 6
```

#### 3. 分阶段滚动更新
```yaml
# 使用 maxSurge 的滚动更新
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 4  # 从后向前逐步更新
    maxUnavailable: 1
    maxSurge: 2  # 允许临时增加副本
replicas: 6
```

#### 4. 暂停更新
```yaml
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 6  # 等于 replicas，暂停所有更新
    maxUnavailable: 0
    maxSurge: 0
replicas: 6
```

### ❌ 错误示例

#### 错误 1：Partition 超过 Replicas
```yaml
# 错误：partition > replicas
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 9  # ❌ 错误：超过副本数
    maxUnavailable: 2
    maxSurge: 3
replicas: 6
```
**问题**：不会更新任何 Pod，且可能导致意外行为

#### 错误 2：负数 Partition
```yaml
# 错误：负数 partition
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: -1  # ❌ 错误：负数无效
```

### 建议的最佳实践

1. **初始部署时使用 `partition: 0`**
2. **滚动更新时从 `partition: replicas` 开始，逐步减少到 0**
3. **金丝雀发布时使用 `partition: replicas - 1` 开始**
4. **永远不要设置 `partition > replicas`**
5. **考虑使用百分比形式的 maxUnavailable 和 maxSurge 以适应扩缩容**

### 滚动更新流程示例

假设要更新一个有 6 个副本的 LeaderWorkerSet：

```bash
# 步骤 1：暂停在最开始
partition: 6  → 不更新任何 Pod

# 步骤 2：金丝雀测试
partition: 5  → 只更新 Pod-5（1个）

# 步骤 3：扩大测试范围
partition: 4  → 更新 Pod-4 和 Pod-5（2个）

# 步骤 4：继续滚动
partition: 2  → 更新 Pod-2,3,4,5（4个）

# 步骤 5：完成更新
partition: 0  → 更新所有 Pod（6个）
```

### 与 MaxSurge 配合使用

当同时使用 partition 和 maxSurge 时：
- maxSurge 只在实际进行滚动更新时生效
- 初始部署不应该应用 maxSurge
- partition 控制更新的范围，maxSurge 控制更新过程中的额外副本

```yaml
# 正确的滚动更新配置
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 3  # 更新后半部分
    maxUnavailable: 1
    maxSurge: 2  # 更新过程中允许额外 2 个副本
replicas: 6
# 结果：更新 Pod-3,4,5，过程中最多有 8 个副本
```