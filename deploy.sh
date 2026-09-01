#!/bin/bash
# ============================================================
# BootMgr 一键部署脚本 — eMMC/SATA 双系统启动管理器
# 适用: RK3566 盒子 (OPHub Armbian, extlinux 引导, U-Boot 从 eMMC 引导)
# 用法: sudo bash deploy.sh
# 功能: 安装依赖 → 部署 /opt/bootmgr → systemd 自启 → 备份 U-Boot env
#       → 配置 bootcmd(bootdev 切换) → 生成 extlinux 双配置
# 安全: bootcmd 修改前自动备份 env; 全程可重复执行(幂等)
# ============================================================
set -u

# ---------- 路径 ----------
BASE=/opt/bootmgr
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"    # 脚本所在目录(含 bootmgr.py/clone.sh)
EMMC_BOOT=/boot
ENV_BACKUP="$BASE/env_backup_$(date +%Y%m%d_%H%M%S).txt"

log()  { echo -e "\033[1;36m[BootMgr]\033[0m $*"; }
warn() { echo -e "\033[1;33m[警告]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
die()  { echo -e "\033[1;31m[错误]\033[0m $*"; exit 1; }

# ---------- 0. 前置检查 ----------
log "=== BootMgr 一键部署 ==="
[ "$(id -u)" -eq 0 ] || die "请以 root 运行: sudo bash deploy.sh"
[ -f "$SRC_DIR/bootmgr.py" ] || die "未找到 $SRC_DIR/bootmgr.py (请与 deploy.sh 放在同一目录)"
[ -f "$SRC_DIR/clone.sh" ]   || die "未找到 $SRC_DIR/clone.sh"
command -v fw_printenv >/dev/null 2>&1 || log "fw_printenv 未安装, 稍后安装"

CUR=$(findmnt -n -o SOURCE / 2>/dev/null)
case "$CUR" in
  /dev/mmcblk0*) ok "当前在 eMMC 系统 ($CUR), 克隆功能可用" ;;
  /dev/sd*)      warn "当前在 SATA 系统 ($CUR), 克隆功能需在 eMMC 系统使用" ;;
  *)             warn "无法确认当前系统介质 ($CUR)" ;;
esac

# ---------- 1. 安装依赖 ----------
log "=== 安装依赖 ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>/dev/null || true
apt-get install -y libubootenv-tool gdisk rsync cloud-guest-utils >/dev/null 2>&1 \
  || apt-get install -y libubootenv-tool gdisk rsync >/dev/null 2>&1 \
  || die "依赖安装失败, 请手动: apt-get install libubootenv-tool gdisk rsync"
ok "依赖已安装 (libubootenv-tool gdisk rsync)"

# ---------- 2. 部署文件 ----------
log "=== 部署文件 ==="
mkdir -p "$BASE"
cp "$SRC_DIR/bootmgr.py" "$SRC_DIR/clone.sh" "$BASE/"
chmod +x "$BASE/bootmgr.py" "$BASE/clone.sh"
# 同步到 SATA rootfs (若存在且当前不在 SATA 系统)
if [ -b /dev/sda2 ] && ! mountpoint -q / 2>/dev/null | grep -q sda; then
  case "$CUR" in
    /dev/mmcblk0*)  # 在 eMMC 系统, 同步到 SATA
      mount /dev/sda2 /mnt 2>/dev/null && {
        [ -d /mnt/opt/bootmgr ] && cp "$BASE/bootmgr.py" "$BASE/clone.sh" /mnt/opt/bootmgr/
        umount /mnt
        ok "已同步到 SATA rootfs"
      } || warn "SATA rootfs 同步跳过"
      ;;
  esac
fi
ok "文件已部署到 $BASE"

# ---------- 3. systemd 服务 ----------
log "=== systemd 服务 ==="
cat > /etc/systemd/system/bootmgr.service <<'EOF'
[Unit]
Description=BootMgr - eMMC/SATA dual boot manager WebUI
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/bootmgr/bootmgr.py
Restart=always
RestartSec=3
WorkingDirectory=/opt/bootmgr

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable bootmgr >/dev/null 2>&1
systemctl restart bootmgr
sleep 1
systemctl is-active bootmgr >/dev/null 2>&1 && ok "bootmgr 服务运行中 (:8080)" || warn "bootmgr 服务未启动, 检查: journalctl -u bootmgr"

# ---------- 4. 备份 U-Boot env ----------
log "=== U-Boot 环境变量 ==="
if command -v fw_printenv >/dev/null 2>&1; then
  fw_printenv > "$ENV_BACKUP" 2>/dev/null && ok "env 已备份: $ENV_BACKUP" || warn "env 备份失败"
else
  warn "fw_printenv 不可用, 跳过 env 备份/配置"
fi

# ---------- 5. 配置 bootcmd (bootdev 切换) ----------
log "=== bootcmd 配置 ==="
if command -v fw_setenv >/dev/null 2>&1 && fw_printenv bootcmd >/dev/null 2>&1; then
  BOOTCMD=$(fw_printenv bootcmd 2>/dev/null | sed 's/^bootcmd=//')
  if echo "$BOOTCMD" | grep -q "bootdev"; then
    ok "bootcmd 已包含 bootdev 逻辑, 跳过"
  else
    warn "bootcmd 不含 bootdev 逻辑, 正在注入 (原值已备份)"
    # 保留原有逻辑, 在 bootcmd_emmc 之前插入 bootdev 判断
    NEWBOOTCMD="${BOOTCMD%run bootcmd_emmc*}if test \${bootdev} = emmc; then sysboot mmc 0:1 any 0x00c00000 /extlinux/extlinux-emmc.conf; else sysboot mmc 0:1 any 0x00c00000 /extlinux/extlinux.conf; fi; run bootcmd_emmc"
    fw_setenv bootcmd "$NEWBOOTCMD" && ok "bootcmd 已更新: $NEWBOOTCMD" || die "bootcmd 写入失败!"
  fi
  # 确保 bootdev 变量存在 (默认 sata)
  BD=$(fw_printenv bootdev 2>/dev/null | sed 's/^bootdev=//')
  if [ "$BD" != "sata" ] && [ "$BD" != "emmc" ]; then
    fw_setenv bootdev sata
    ok "bootdev 初始化为 sata"
  fi
else
  warn "fw_setenv 不可用, 跳过 bootcmd 配置 (请手动配置)"
fi

# ---------- 6. 生成 extlinux 双配置 ----------
log "=== extlinux 引导配置 ==="
EMMC_UUID=$(findmnt -n -o UUID / 2>/dev/null)
if [ -f "$EMMC_BOOT/extlinux/extlinux.conf" ] && [ -n "$EMMC_UUID" ]; then
  # extlinux.conf = 日常(SATA 指向由 clone.sh 更新); 这里确保 emmc 恢复配置存在
  if [ ! -f "$EMMC_BOOT/extlinux/extlinux-emmc.conf" ]; then
    cp "$EMMC_BOOT/extlinux/extlinux.conf" "$EMMC_BOOT/extlinux/extlinux-emmc.conf"
    sed -i "s|root=UUID=[0-9a-f-]*|root=UUID=$EMMC_UUID|g" "$EMMC_BOOT/extlinux/extlinux-emmc.conf"
    ok "已生成 extlinux-emmc.conf (恢复配置, root=$EMMC_UUID)"
  else
    ok "extlinux-emmc.conf 已存在"
  fi
else
  warn "未找到 /boot/extlinux/extlinux.conf 或无法获取 eMMC UUID, 跳过"
fi

# ---------- 7. 完成 ----------
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "====================================================="
echo "  ✅ BootMgr 部署完成!"
echo "  WebUI:  http://${IP:-<盒子IP>}:8080"
echo "  文件:   $BASE (bootmgr.py + clone.sh)"
echo "  env备份: $ENV_BACKUP"
echo "-----------------------------------------------------"
echo "  使用说明:"
echo "  - 切换启动: WebUI 按钮 (bootdev=sata/emmc)"
echo "  - 克隆系统: 在 eMMC 系统里 WebUI 点[克隆/一键恢复]"
echo "  - 克隆会清空 SATA 盘并自动 bootdev=sata"
echo "====================================================="
