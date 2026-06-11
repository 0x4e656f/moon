#!/bin/bash

# 默认构建类型
BUILD_TYPE=Debug

# 检查参数
if [[ "$1" == "release" || "$1" == "Release" ]]; then
    BUILD_TYPE=Release
fi

# 构建目录格式
BUILD_DIR="_build_linux_${BUILD_TYPE,,}"  # 转小写

# 创建目录
if [ ! -d "$BUILD_DIR" ]; then
    mkdir "$BUILD_DIR"
fi

cd "$BUILD_DIR" || exit

# 运行 CMake
cmake -DCMAKE_BUILD_TYPE=$BUILD_TYPE -DBUILD_SHARED_LIBS=OFF ..
