#!/bin/bash
set -e

# ==================== 0. 路径初始化 ====================
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SRC_DIR/build_gcc"
OUT_DIR="$BUILD_DIR/py_release"

# ==================== 1. 参数处理 ====================
BUILD_TYPE="${1:-dll}"

if [ "$BUILD_TYPE" = "clean" ]; then
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        echo "[INFO] 已清理 $BUILD_DIR"
    else
        echo "[INFO] build_gcc 目录不存在，无需清理"
    fi
    exit 0
fi

if [ "$BUILD_TYPE" != "dll" ]; then
    echo "用法: $0 [dll|clean]"
    echo "  dll   - 编译静态 opencc.dll（仅依赖 KERNEL32.dll + msvcrt.dll）"
    echo "  clean - 清理 build_gcc 目录"
    exit 1
fi

# ==================== 2. 检查 7z ====================
if ! command -v 7z &>/dev/null; then
    echo "[INFO] 7z 未安装，正在通过 pacman 安装..."
    pacman -S --noconfirm p7zip 2>/dev/null || {
        echo "[ERROR] 安装 7z 失败，请手动安装: pacman -S p7zip"
        exit 1
    }
    echo "[INFO] 7z 安装完成"
fi

# ==================== 3. 打印构建信息 ====================
echo ""
echo "============================================================"
echo " OpenCC MinGW GCC 构建脚本"
echo "============================================================"
echo " 源码目录 : $SRC_DIR"
echo " 构建目录 : $BUILD_DIR"
echo " 输出目录 : $OUT_DIR"
echo " 构建类型 : $BUILD_TYPE"
echo "============================================================"
echo ""

# ==================== 4. CMake 配置 ====================
echo "[INFO] 开始 CMake 配置..."

cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -G "MinGW Makefiles" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_PYTHON=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-Os -ffunction-sections -fdata-sections -fno-ident -fomit-frame-pointer -fmerge-all-constants -flto" \
    -DCMAKE_CXX_FLAGS="-Os -ffunction-sections -fdata-sections -fno-ident -fomit-frame-pointer -fvisibility=hidden -fvisibility-inlines-hidden -fmerge-all-constants -flto" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--gc-sections -static-libgcc -static-libstdc++ -static -Wl,-s -Wl,--build-id=none -Wl,--exclude-libs=ALL -Wl,--omagic" \
    -DENABLE_GTEST=OFF \
    -DENABLE_BENCHMARK=OFF \
    -DBUILD_OPENCC_JIEBA_PLUGIN=OFF

echo "[INFO] CMake 配置成功"

# ==================== 5. 编译 ====================
echo ""
echo "[INFO] 开始编译..."

cmake --build "$BUILD_DIR" --config Release -j$(nproc)

echo "[INFO] 编译成功"

# ==================== 6. 准备输出目录 ====================
echo ""
echo "[INFO] 准备输出目录..."

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# ==================== 7. 收集 DLL ====================
echo "[INFO] 收集 DLL 产物..."

if [ -f "$BUILD_DIR/src/libopencc.dll" ]; then
    cp "$BUILD_DIR/src/libopencc.dll" "$OUT_DIR/opencc.dll"
    strip --strip-all "$OUT_DIR/opencc.dll"
    echo "  [+] libopencc.dll -> opencc.dll"
else
    echo "[ERROR] 找不到 $BUILD_DIR/src/libopencc.dll"
    ls -la "$BUILD_DIR/src/"*.dll 2>/dev/null || echo "  无 .dll 文件"
    exit 1
fi

# ==================== 8. 复制 Python 封装 ====================
if [ -f "$SRC_DIR/python/opencc/RegionalReplacer.py" ]; then
    cp "$SRC_DIR/python/opencc/RegionalReplacer.py" "$OUT_DIR/"
    echo "  [+] RegionalReplacer.py"
else
    echo "  [!] 警告: 找不到 RegionalReplacer.py"
fi

# ==================== 9. 准备 ZIP 临时目录 ====================
echo ""
echo "[INFO] 准备 ZIP 打包..."

ZIP_TMP="$BUILD_DIR/zip_tmp"
rm -rf "$ZIP_TMP"
mkdir -p "$ZIP_TMP/jieba_dict"

cp "$SRC_DIR/data/config/"*.json "$ZIP_TMP/" 2>/dev/null || true
cp "$SRC_DIR/plugins/jieba/data/config/"*.json "$ZIP_TMP/" 2>/dev/null || true
cp "$BUILD_DIR/data/"*.ocd2 "$ZIP_TMP/" 2>/dev/null || true
cp "$SRC_DIR/plugins/jieba/deps/cppjieba/dict/"*.utf8 "$ZIP_TMP/jieba_dict/" 2>/dev/null || true

if [ -f "$BUILD_DIR/plugins/jieba/jieba_dict/jieba_merged.ocd2" ]; then
    cp "$BUILD_DIR/plugins/jieba/jieba_dict/jieba_merged.ocd2" "$ZIP_TMP/jieba_dict/"
fi

# ==================== 10. 打包 opencc_data.zip ====================
echo "[INFO] 打包 opencc_data.zip..."

rm -f "$OUT_DIR/opencc_data.zip"

(
    cd "$ZIP_TMP" && \
    7z a -tzip -mx=9 "$OUT_DIR/opencc_data.zip" . > /dev/null
)

if [ -f "$OUT_DIR/opencc_data.zip" ]; then
    rm -rf "$ZIP_TMP"
    echo "[INFO] 已生成 opencc_data.zip"
else
    echo "[ERROR] 打包失败！"
    exit 1
fi

# ==================== 11. 完成 ====================
echo ""
echo "============================================================"
echo " 构建完成！"
echo "============================================================"
echo " 输出目录 : $OUT_DIR"
echo ""
ls -la "$OUT_DIR/"
echo ""
echo " DLL 依赖检查:"
objdump -p "$OUT_DIR/opencc.dll" | grep "DLL Name:" || echo "  (objdump 不可用，跳过)"