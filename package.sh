#!/bin/bash
# ============================================================
# fxpa 打包脚本 — 编译 + 打包成 .tar.gz
# 用法:
#   ./package.sh              # 打当前架构的包
#   ./package.sh --universal  # 通用二进制（arm64 + x86_64）
#   ./package.sh 0.0.1-beta   # 指定版本号（默认检测 git tag）
# ============================================================
set -euo pipefail

UNIVERSAL=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        *) VERSION="$arg" ;;
    esac
done

# 检测版本号
if [ -z "$VERSION" ]; then
    VERSION=$(git describe --tags --always 2>/dev/null || echo "dev")
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

echo "  ════════════════════════════"
echo "  版本: $VERSION"
echo "  架构: $([ "$UNIVERSAL" = true ] && echo 'arm64 + x86_64' || echo '当前架构')"
echo "  ════════════════════════════"

# 编译
if [ "$UNIVERSAL" = true ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR=".build/apple/Products/Release"
else
    swift build -c release
    ARCH=$(uname -m)
    BIN_DIR=".build/$ARCH-apple-macosx/release"
fi

# 打包
PKG="fxpa-${VERSION}"
rm -rf "$PKG" "${PKG}.tar.gz"
mkdir -p "$PKG"

cp "$BIN_DIR/fxpa" "$PKG/"
cp -R "$BIN_DIR/fxpa_FXPAKit.bundle" "$PKG/" 2>/dev/null || {
    # 回退：bundle 可能在 build 目录下
    BUNDLE=$(find .build -name "fxpa_FXPAKit.bundle" -type d 2>/dev/null | head -1)
    [ -n "$BUNDLE" ] && cp -R "$BUNDLE" "$PKG/"
}

tar czf "${PKG}.tar.gz" "$PKG"
rm -rf "$PKG"

echo ""
echo "  $(printf '\033[0;32m打包完成\033[0m')"
echo ""
ls -lh "${PKG}.tar.gz"
echo ""
echo "  解压即用:"
echo "    tar xzf ${PKG}.tar.gz"
echo "    ./${PKG}/fxpa --version"
