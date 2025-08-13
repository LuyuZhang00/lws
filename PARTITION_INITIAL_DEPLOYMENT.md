# LeaderWorkerSet 初始部署时 Partition 参数处理说明

## 背景

在 Kubernetes StatefulSet 中，`partition` 参数用于滚动更新场景，控制哪些 Pod 需要更新到新版本。然而，在**初始部署**时使用 partition 参数是没有意义的，因为：

1. 没有"旧版本"Pod 需要保留
2. 所有 Pod 都是新创建的
3. 不存在"更新"的概念

## 问题描述

用户报告的问题：
```yaml
# 用户配置
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 9  # 期望"暂停部署"？
    maxSurge: 3
replicas: 6
```

原始行为：
- 初始创建 9 个 Pod（replicas + maxSurge）
- 然后缩减到 6 个 Pod
- 造成资源浪费和混乱

## 解决方案

### 核心原则
**初始部署时忽略 partition 参数**，确保所有 Pod 正常创建。

### 实现细节

#### 1. 控制器行为

```go
// 初始部署检测
if sts == nil {  // StatefulSet 不存在
    return 0, lwsReplicas, nil  // partition=0，忽略用户设置
}

if stsReplicas == 0 {  // StatefulSet 刚创建，还没有 Pod
    return 0, lwsReplicas, nil  // partition=0，忽略用户设置
}

// 只有在真正的滚动更新时才使用 partition
if stsReplicas > 0 {
    // 使用用户设置的 partition
}
```

#### 2. Webhook 警告

当用户在创建 LWS 时设置了 partition > 0，会收到警告：
```
Warning: partition value 9 will be ignored during initial deployment. 
All 6 replicas will be created. Partition only takes effect during rolling updates.
```

#### 3. 验证规则

- `partition < 0`：错误，拒绝创建
- `partition > replicas`：错误，提示无效配置
- `partition > 0` 在初始创建时：警告，但允许创建

## 行为对比

### 旧行为
| 场景 | 用户设置 | 实际行为 | 问题 |
|-----|---------|---------|------|
| 初始部署 | partition=9, replicas=6 | 可能创建 9 个 Pod | 资源浪费 |
| 初始部署 | partition=3, replicas=6 | partition 生效 | 只创建部分 Pod |

### 新行为
| 场景 | 用户设置 | 实际行为 | 说明 |
|-----|---------|---------|------|
| 初始部署 | partition=9, replicas=6 | 创建 6 个 Pod，警告用户 | partition 被忽略 |
| 初始部署 | partition=3, replicas=6 | 创建 6 个 Pod，警告用户 | partition 被忽略 |
| 滚动更新 | partition=3, replicas=6 | 更新 Pod 3-5 | partition 正常生效 |

## 最佳实践建议

### 初始部署
```yaml
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 0  # 或者不设置
    maxUnavailable: 2
    maxSurge: 0   # 初始部署不需要 surge
replicas: 6
```

### 滚动更新
```yaml
# 步骤 1：开始滚动更新（金丝雀）
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 5  # 只更新最后一个 Pod
    maxUnavailable: 1
    maxSurge: 1   # 允许临时增加副本
replicas: 6

# 步骤 2：扩大更新范围
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 3  # 更新后半部分
    maxUnavailable: 2
    maxSurge: 2
replicas: 6

# 步骤 3：完成更新
rolloutStrategy:
  rollingUpdateConfiguration:
    partition: 0  # 更新所有 Pod
    maxUnavailable: 2
    maxSurge: 2
replicas: 6
```

## 迁移指南

如果您的 LWS 配置中在初始部署时设置了 partition：

1. **无需修改**：新版本会自动忽略初始部署时的 partition
2. **建议调整**：将初始部署的 partition 设置为 0 或删除
3. **注意警告**：关注 webhook 的警告信息

## 技术细节

### 为什么这样设计？

1. **语义清晰**：partition 是滚动更新的概念，不应影响初始部署
2. **行为一致**：与 Kubernetes Deployment 等资源的行为保持一致
3. **避免困惑**：防止用户误解 partition 的作用
4. **简化配置**：用户不需要为初始部署特别调整 partition

### 兼容性

- **向后兼容**：现有配置仍然可以工作
- **行为改进**：更合理的默认行为
- **清晰提示**：通过警告帮助用户理解

## 总结

这个改进确保了：
1. **初始部署的可预测性**：总是创建所有请求的副本
2. **滚动更新的灵活性**：partition 在需要时正常工作
3. **用户体验的改善**：清晰的警告和文档