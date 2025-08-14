#!/bin/bash
# 简化的构建脚本，避免 buildx 问题

set -e

# 设置变量
IMG="${1:-lws:test}"
PLATFORM="${2:-linux/amd64}"

echo "Building LeaderWorkerSet image: $IMG"
echo "Platform: $PLATFORM"

# 方法1：使用传统 docker build（推荐用于本地测试）
build_traditional() {
    echo "Using traditional docker build..."
    docker build -t "$IMG" \
        --build-arg BASE_IMAGE=gcr.io/distroless/static:nonroot \
        --build-arg BUILDER_IMAGE=golang:1.24 \
        --build-arg CGO_ENABLED=0 \
        .
}

# 方法2：使用 buildx（如果可用）
build_with_buildx() {
    echo "Using docker buildx..."
    
    # 检查 buildx 是否可用
    if ! docker buildx version &> /dev/null; then
        echo "Docker buildx not available, falling back to traditional build"
        build_traditional
        return
    fi
    
    # 创建或使用现有的 builder
    BUILDER_NAME="lws-builder"
    if ! docker buildx ls | grep -q "$BUILDER_NAME"; then
        echo "Creating buildx builder: $BUILDER_NAME"
        docker buildx create --name "$BUILDER_NAME" --use
    else
        echo "Using existing buildx builder: $BUILDER_NAME"
        docker buildx use "$BUILDER_NAME"
    fi
    
    # 构建镜像
    docker buildx build \
        --platform="$PLATFORM" \
        --tag "$IMG" \
        --build-arg BASE_IMAGE=gcr.io/distroless/static:nonroot \
        --build-arg BUILDER_IMAGE=golang:1.24 \
        --build-arg CGO_ENABLED=0 \
        --load \
        .
}

# 主逻辑
echo "Checking Docker version..."
docker version --format '{{.Server.Version}}'

# 尝试使用 buildx，失败则使用传统方式
if [ "${USE_BUILDX:-false}" = "true" ]; then
    build_with_buildx
else
    build_traditional
fi

echo "Build completed successfully!"
echo ""
echo "To load image to kind cluster:"
echo "  kind load docker-image $IMG"
echo ""
echo "To push to registry:"
echo "  docker push $IMG"