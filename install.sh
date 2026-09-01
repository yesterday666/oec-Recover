#!/bin/bash
# ============================================================
# BootMgr 在线安装 — 从 GitHub 拉取仓库并一键部署
# 用法: curl -sSL https://raw.githubusercontent.com/yesterday666/oec-Recover/main/install.sh | sudo bash
# ============================================================
set -u
REPO="https://github.com/yesterday666/oec-Recover.git"
TMP=$(mktemp -d /tmp/bootmgr-install.XXXXXX)

echo "=== BootMgr 在线安装 ==="
echo "拉取仓库: $REPO"

if ! command -v git >/dev/null 2>&1; then
  echo "安装 git..."
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y git >/dev/null 2>&1 || { echo "ERROR: git 安装失败"; exit 1; }
fi

git clone --depth 1 "$REPO" "$TMP" 2>&1 | tail -2 || { echo "ERROR: 拉取仓库失败"; rm -rf "$TMP"; exit 1; }

echo "仓库已拉取, 开始部署..."
cd "$TMP" || exit 1
sudo bash deploy.sh
RC=$?

rm -rf "$TMP"
exit $RC
