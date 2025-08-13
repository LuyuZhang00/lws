# Go 测试文件运行指南

## 问题说明

当你尝试直接运行单个 Go 测试文件时遇到错误：
```bash
$ go test ./pkg/webhooks/leaderworkerset_webhook_partition_test.go
# command-line-arguments [command-line-arguments.test]
pkg/webhooks/leaderworkerset_webhook_partition_test.go:109:14: undefined: LeaderWorkerSetWebhook
FAIL    command-line-arguments [build failed]
```

## 错误原因

Go 编译器在编译测试文件时需要知道所有引用的类型定义。当你只指定一个文件时，编译器无法找到在其他文件中定义的类型（如 `LeaderWorkerSetWebhook`）。

## 正确的运行方式

### 1. 运行特定测试函数（推荐）

```bash
# 基本用法
go test ./pkg/webhooks -run TestPartitionValidation

# 带详细输出
go test -v ./pkg/webhooks -run TestPartitionValidation

# 运行多个匹配的测试
go test -v ./pkg/webhooks -run "TestPartition.*"

# 从项目根目录运行
go test -v sigs.k8s.io/lws/pkg/webhooks -run TestPartitionValidation
```

### 2. 运行整个包的测试

```bash
# 运行 webhooks 包的所有测试
go test ./pkg/webhooks

# 带详细输出
go test -v ./pkg/webhooks

# 带覆盖率
go test -v -cover ./pkg/webhooks

# 从包目录内运行
cd pkg/webhooks
go test -v
```

### 3. 运行子测试

如果测试使用了 `t.Run()`（子测试），可以运行特定的子测试：

```bash
# 运行特定的子测试
go test -v ./pkg/webhooks -run "TestPartitionValidation/Valid_partition_equal_to_0"

# 使用正则表达式匹配多个子测试
go test -v ./pkg/webhooks -run "TestPartitionValidation/.*Invalid.*"
```

### 4. 包含多个源文件（不推荐）

虽然可以这样做，但不推荐，因为可能遗漏依赖：

```bash
go test ./pkg/webhooks/leaderworkerset_webhook_partition_test.go \
        ./pkg/webhooks/leaderworkerset_webhook.go \
        ./pkg/webhooks/utils.go  # 如果有其他依赖
```

## 测试命令选项

### 常用选项

```bash
# 详细输出
go test -v ./pkg/webhooks

# 运行特定测试
go test -run TestName ./pkg/webhooks

# 显示测试覆盖率
go test -cover ./pkg/webhooks

# 生成覆盖率报告
go test -coverprofile=coverage.out ./pkg/webhooks
go tool cover -html=coverage.out

# 设置超时
go test -timeout 30s ./pkg/webhooks

# 并行运行测试
go test -parallel 4 ./pkg/webhooks

# 运行基准测试
go test -bench=. ./pkg/webhooks

# 显示测试时间
go test -v -run TestPartitionValidation ./pkg/webhooks | grep -E "PASS|FAIL"
```

### 调试选项

```bash
# 禁用测试缓存
go test -count=1 ./pkg/webhooks

# 显示编译过程
go test -x ./pkg/webhooks

# 竞态检测
go test -race ./pkg/webhooks

# 短测试模式（跳过长时间运行的测试）
go test -short ./pkg/webhooks
```

## 项目特定示例

对于 LeaderWorkerSet 项目：

```bash
# 运行所有 webhook 测试
go test -v ./pkg/webhooks/...

# 运行特定的 partition 验证测试
go test -v ./pkg/webhooks -run TestPartitionValidation

# 运行所有控制器测试
go test -v ./pkg/controllers/...

# 运行特定的滚动更新测试
go test -v ./pkg/controllers -run TestRollingUpdateParametersWithMaxSurge

# 运行所有测试并生成覆盖率
go test -v -cover ./pkg/...

# 运行集成测试
go test -v ./test/integration/...

# 运行 e2e 测试
go test -v ./test/e2e/...
```

## 文件组织最佳实践

### 测试文件命名
- 单元测试：`filename_test.go`（与源文件在同一包）
- 集成测试：放在 `test/integration/` 目录
- E2E 测试：放在 `test/e2e/` 目录

### 测试文件结构
```go
package webhooks  // 与被测试的包相同

import (
    "testing"
    // 其他导入
)

func TestFunctionName(t *testing.T) {
    // 测试逻辑
}

func TestAnotherFunction(t *testing.T) {
    t.Run("SubTest1", func(t *testing.T) {
        // 子测试 1
    })
    t.Run("SubTest2", func(t *testing.T) {
        // 子测试 2
    })
}
```

## 常见问题

### Q: 为什么不能直接运行单个测试文件？
A: Go 需要编译整个包来解析类型依赖。单个文件可能引用其他文件中定义的类型。

### Q: 如何只运行失败的测试？
A: 使用 `-run` 参数指定测试名称：
```bash
go test -v ./pkg/webhooks -run TestThatFailed
```

### Q: 如何查看测试覆盖了哪些代码？
A: 生成并查看覆盖率报告：
```bash
go test -coverprofile=cover.out ./pkg/webhooks
go tool cover -html=cover.out
```

### Q: 测试运行太慢怎么办？
A: 
1. 使用 `-short` 跳过长测试
2. 使用 `-parallel` 并行运行
3. 使用测试缓存（默认启用）
4. 只运行特定的测试

## 总结

正确的方式是使用包路径运行测试，而不是直接指定文件：
```bash
# ✅ 正确
go test -v ./pkg/webhooks -run TestPartitionValidation

# ❌ 错误
go test ./pkg/webhooks/leaderworkerset_webhook_partition_test.go
```

这样 Go 编译器可以正确解析所有依赖，成功运行测试。