#!/bin/bash
# ============================================================
# fxpa Homebrew 发布脚本
# 用法:
#   ./release.sh 0.0.1-beta                    # 打 tag + 发 release + 更新 formula
#   ./release.sh 0.0.1-beta --skip-commit      # 已有 commit，只打 tag 发 release
#   ./release.sh 0.0.1-beta --dry-run           # 预演，不实际推送
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}  %s\n" "$*"; exit 1; }

# ── 参数 ──
VERSION="${1:-}"
SKIP_COMMIT=false
DRY_RUN=false
shift 2>/dev/null || true
for arg in "$@"; do
    case "$arg" in
        --skip-commit) SKIP_COMMIT=true ;;
        --dry-run) DRY_RUN=true ;;
        *) err "未知参数: $arg" ;;
    esac
done

[ -z "$VERSION" ] && err "用法: ./release.sh <版本号> [--skip-commit] [--dry-run]\n示例: ./release.sh 0.0.1-beta"

# ── 检查依赖 ──
command -v gh >/dev/null 2>&1 || err "需要安装 gh CLI: brew install gh\n然后 gh auth login"
command -v git >/dev/null 2>&1 || err "需要 git"

# ── 仓库信息（自动检测）──
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
[ -z "$REMOTE_URL" ] && err "未找到 git remote origin"

# 从 remote URL 提取 owner/repo
# 支持格式: https://github.com/owner/repo.git 或 git@github.com:owner/repo.git
if echo "$REMOTE_URL" | grep -q "github.com"; then
    OWNER=$(echo "$REMOTE_URL" | sed -E 's|.*github.com[:/]([^/]+)/.*|\1|')
    REPO=$(echo "$REMOTE_URL" | sed -E 's|.*github.com[:/][^/]+/([^./]+).*|\1|')
else
    err "仅支持 GitHub 仓库，当前 remote: $REMOTE_URL"
fi

FORMULA_NAME="fxpa"
INFO="iOS 包体积统一分析工具"
HOMEPAGE="https://github.com/${OWNER}/${REPO}"

echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  fxpa Homebrew 发布                      │"
echo "  ├─────────────────────────────────────────┤"
echo "  │  版本:    ${VERSION}"
echo "  │  仓库:    ${OWNER}/${REPO}"
echo "  │  DryRun:  ${DRY_RUN}"
echo "  └─────────────────────────────────────────┘"
echo ""

# ── Step 1: 提交 & 打 tag ──
if [ "$SKIP_COMMIT" = false ]; then
    if [ "$DRY_RUN" = false ]; then
        if ! git diff --quiet || ! git diff --cached --quiet; then
            info "Step 1/4: 提交变更 ..."
            git add -A
            git commit -m "release: ${VERSION}"
        else
            info "Step 1/4: 无变更，跳过 commit"
        fi
        git tag "$VERSION" 2>/dev/null || warn "tag ${VERSION} 已存在，跳过"
    else
        info "[dry-run] Step 1/4: git tag ${VERSION}"
    fi
fi

# ── Step 2: 推送 tag ──
if [ "$DRY_RUN" = false ]; then
    info "Step 2/4: 推送代码 & tag ..."
    git push origin main 2>&1 | tail -1
    git push origin "$VERSION" 2>&1 | tail -1
else
    info "[dry-run] Step 2/4: git push origin main && git push origin ${VERSION}"
fi

# ── Step 3: 创建 GitHub Release + 获取 SHA256 ──
TARBALL_URL="https://github.com/${OWNER}/${REPO}/archive/refs/tags/${VERSION}.tar.gz"

if [ "$DRY_RUN" = false ]; then
    info "Step 3/4: 创建 GitHub Release ..."
    if gh release view "$VERSION" --repo "${OWNER}/${REPO}" >/dev/null 2>&1; then
        warn "Release ${VERSION} 已存在"
    else
        gh release create "$VERSION" \
            --repo "${OWNER}/${REPO}" \
            --title "${VERSION}" \
            --notes "fxpa ${VERSION}" \
            --prerelease 2>&1 | tail -3
    fi

    info "计算 SHA256 ..."
    SHA256=$(curl -sL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')
    [ -z "$SHA256" ] && err "无法下载 tarball 计算 SHA256"
    echo "  SHA256: ${SHA256}"
else
    info "[dry-run] Step 3/4: gh release create ${VERSION}"
    SHA256="DRY_RUN_PLACEHOLDER"
fi

# ── Step 4: 生成 Formula 并推到本仓库的 homebrew 分支 ──
TAP_BRANCH="homebrew"
info "Step 4/4: 更新 Formula → ${OWNER}/${REPO}@${TAP_BRANCH} ..."

cat > /tmp/${FORMULA_NAME}.rb << FORMULA
class Fxpa < Formula
  desc "${INFO}"
  homepage "${HOMEPAGE}"
  url "${TARBALL_URL}"
  sha256 "${SHA256}"
  license "MIT"
  version "${VERSION}"

  depends_on xcode: "15.0"
  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/${FORMULA_NAME}"
  end

  test do
    system "#{bin}/#{FORMULA_NAME}", "--version"
  end
end
FORMULA

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "  ═══ Formula 预览 ═══"
    cat "/tmp/${FORMULA_NAME}.rb"
    echo "  ════════════════════"
    echo ""
    info "Dry run 完成，未推送任何内容"
    exit 0
fi

# 用 git subtree 把 Formula 目录推到 homebrew 分支（孤立分支，只有 formula 文件）
CURRENT_BRANCH=$(git branch --show-current)
# 创建空的 homebrew 分支内容
TEMP_DIR="/tmp/homebrew-branch-$$"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
cp "/tmp/${FORMULA_NAME}.rb" "$TEMP_DIR/${FORMULA_NAME}.rb"
cd "$TEMP_DIR"
git init
git checkout -b "$TAP_BRANCH"
git add "${FORMULA_NAME}.rb"
git commit -m "fxpa ${VERSION}"
git push -f "https://github.com/${OWNER}/${REPO}.git" "$TAP_BRANCH" 2>&1 | tail -1
rm -rf "$TEMP_DIR"
cd "$REPO_DIR"

echo ""
echo "  ═══════════════════════════════════"
echo "  $(printf "${GREEN}发布完成${NC}")"
echo ""
echo "  版本:   ${VERSION}"
echo "  SHA256: ${SHA256}"
echo ""
echo "  用户安装："
echo "    brew install ${OWNER}/${REPO}/${FORMULA_NAME}"
echo ""
echo "  或者一步安装："
echo "    brew tap ${OWNER}/${REPO} https://github.com/${OWNER}/${REPO}.git"
echo "    brew install ${FORMULA_NAME}"
echo "  ═══════════════════════════════════"
echo ""
