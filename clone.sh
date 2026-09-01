#!/bin/bash
# ============================================================
# bootmgr clone.sh — 克隆 eMMC 系统到 SATA 盘（一键恢复/初始化）
# 适用: RK3566 盒子 (OPHub Armbian, extlinux 引导, U-Boot 从 eMMC 引导)
# 用法: clone.sh [--force]   # --force=格式化已有分区的 sda
# 方案: rsync 文件级克隆 (只拷贝实际数据, 不是 dd 全盘)
# 架构: U-Boot 从 eMMC 引导, rootfs 在 SATA; 内核更新统一写 eMMC /boot
# 输出: 进度写到 /opt/bootmgr/clone.progress, 日志 /opt/bootmgr/clone.log
# ============================================================
set -u
SRC=/dev/mmcblk0
DST=/dev/sda
STATE=/opt/bootmgr/clone.progress
LOG=/opt/bootmgr/clone.log
FORCE=0
MNT_TGT=/run/bootmgr_clone_root    # sda2 挂载点 (放 /run 避免被 rsync 自身扫到)
MNT_BT=/run/bootmgr_clone_boot     # sda1 挂载点
[ "${1:-}" = "--force" ] && FORCE=1

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
step() { echo "STEP=$1 PROGRESS=$2" > "$STATE"; log "$1"; }

# ---------- 前置检查 ----------
step "check" 1
if [ ! -b "$SRC" ]; then log "ERROR: 源 $SRC 不存在"; echo "ERROR=source-missing" >> "$STATE"; exit 1; fi
if [ ! -b "$DST" ]; then log "ERROR: 目标 $DST 不存在"; echo "ERROR=dest-missing" >> "$STATE"; exit 1; fi
# 必须从 eMMC 运行本脚本（防止从 SATA 系统误操作）
CUR=$(findmnt -n -o SOURCE /)
case "$CUR" in
  /dev/mmcblk0*) ;;
  *) log "ERROR: 当前系统不在 eMMC 上 ($CUR)，克隆必须从 eMMC 恢复系统执行"; echo "ERROR=not-on-emmc" >> "$STATE"; exit 1;;
esac
# 工具检查
for t in sgdisk mkfs.ext4 rsync tune2fs blkid; do
  command -v $t >/dev/null 2>&1 || { log "ERROR: 缺少工具 $t"; echo "ERROR=missing-tool" >> "$STATE"; exit 1; }
done
# 动态检测 eMMC UUID (兼容不同机器/重装后的变化)
EMMC_UUID=$(findmnt -n -o UUID /)
EMMC_BOOT_UUID=$(findmnt -n -o UUID /boot)
log "eMMC root UUID=$EMMC_UUID, boot UUID=$EMMC_BOOT_UUID"

# ---------- 目标盘清理 + 建分区 ----------
step "wipe" 5
HAS_PART=$(sgdisk -p "$DST" 2>/dev/null | grep -cE '^ +[0-9]+ +[0-9]+')
if [ "$HAS_PART" -gt 0 ] && [ "$FORCE" -ne 1 ]; then
  log "ERROR: $DST 已有 $HAS_PART 个分区且未带 --force"; echo "ERROR=has-partitions" >> "$STATE"; exit 1
fi
if [ "$HAS_PART" -gt 0 ]; then
  log "警告: 格式化并清空 $DST (已有 $HAS_PART 个分区)"
fi
# 重建 GPT: 分区1 = boot 512M, 分区2 = rootfs 占满剩余
sgdisk -Z "$DST" >> "$LOG" 2>&1
sgdisk -n 1:2048:+512M -t 1:8300 -c 1:BOOT "$DST" >> "$LOG" 2>&1
sgdisk -n 2:0:0   -t 2:8300 -c 2:ROOTFS "$DST" >> "$LOG" 2>&1
partprobe "$DST" 2>/dev/null || true
sleep 2
log "分区已重建: $(lsblk -o NAME,SIZE -n "$DST" | tr '\n' ' ')"

# ---------- 格式化 ----------
step "mkfs" 8
mkfs.ext4 -q -L BOOT "$DST"1 >> "$LOG" 2>&1
mkfs.ext4 -q -L ROOTFS "$DST"2 >> "$LOG" 2>&1
log "格式化完成 (ext4, BOOT + ROOTFS)"

# ---------- rsync 文件级克隆 (只拷贝实际数据) ----------
step "rsync-root" 15
mkdir -p "$MNT_TGT" "$MNT_BT"
mount "$DST"2 "$MNT_TGT" 2>/dev/null || { log "ERROR: 挂载 $DST 2 失败"; echo "ERROR=mount2" >> "$STATE"; exit 1; }
log "开始 rsync / → sda2 (排除 /proc /sys /dev /run /tmp 等虚拟文件系统)"
# -a 归档 -H 硬链接 -A ACL -X xattr -x 单文件系统(跳过挂载点) --numeric-ids 保留UID/GID
# 进度输出解析到 STATE 供 WebUI 显示; 日志只保留统计摘要(不刷屏)
rsync -aHAXx --numeric-ids --info=progress2 --stats / "$MNT_TGT/" \
  2> >(stdbuf -oL tr '\r' '\n' | while IFS= read -r line; do
        # 解析 " 1,234,567  45%  12.3MB/s ..." 中的百分比 (仅数字行)
        PCT=$(echo "$line" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
        if [ -n "$PCT" ]; then
          P=$(( PCT * 68 / 100 + 15 ))   # 15~83 映射
          [ "$P" -gt 83 ] && P=83
          echo "STEP=rsync-root PROGRESS=$P" > "$STATE"
        fi
      done) > >(grep -E "Number of files|Total file size|Total transferred|Literal data|sent .* bytes|total size" >> "$LOG")
RS_RC=${PIPESTATUS[0]}
if [ "$RS_RC" -ne 0 ]; then log "ERROR: rsync rootfs 失败 rc=$RS_RC"; echo "ERROR=rsync-root-failed" >> "$STATE"; exit 1; fi
log "rootfs 克隆完成"
step "rsync-boot" 85
mount "$DST"1 "$MNT_BT" 2>/dev/null || { log "ERROR: 挂载 $DST 1 失败"; echo "ERROR=mount1" >> "$STATE"; exit 1; }
rsync -aHAX --info=progress2 /boot/ "$MNT_BT/" \
  2> >(stdbuf -oL tr '\r' '\n' | while IFS= read -r line; do
        PCT=$(echo "$line" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
        if [ -n "$PCT" ]; then
          P=$(( PCT * 4 / 100 + 85 ))    # 85~88 映射
          echo "STEP=rsync-boot PROGRESS=$P" > "$STATE"
        fi
      done) > >(grep -E "sent .* bytes|total size" >> "$LOG")
RS_RC=${PIPESTATUS[0]}
if [ "$RS_RC" -ne 0 ]; then log "ERROR: rsync boot 失败 rc=$RS_RC"; echo "ERROR=rsync-boot-failed" >> "$STATE"; exit 1; fi
log "boot 克隆完成"

# ---------- 生成新 UUID (双盘无冲突) ----------
step "uuid" 90
tune2fs -U random "$DST"1 >/dev/null 2>&1
tune2fs -U random "$DST"2 >/dev/null 2>&1
NEWBOOT=$(blkid -s UUID -o value "$DST"1)
NEWROOT=$(blkid -s UUID -o value "$DST"2)
log "新 UUID: boot=$NEWBOOT root=$NEWROOT"
if [ -z "$NEWBOOT" ] || [ -z "$NEWROOT" ]; then
  log "ERROR: 生成新 UUID 失败"; echo "ERROR=uuid-failed" >> "$STATE"; exit 1
fi

# ---------- 更新 SATA 盘内引导配置 ----------
step "config" 93
# sda1 extlinux.conf: root= 指向新 rootfs
sed -i "s|root=UUID=[0-9a-f-]*|root=UUID=$NEWROOT|g" "$MNT_BT/extlinux/extlinux.conf" 2>/dev/null
# sda1 恢复配置 extlinux-emmc.conf: root 指向 eMMC
cp "$MNT_BT/extlinux/extlinux.conf" "$MNT_BT/extlinux/extlinux-emmc.conf" 2>/dev/null
sed -i "s|root=UUID=[0-9a-f-]*|root=UUID=$EMMC_UUID|g" "$MNT_BT/extlinux/extlinux-emmc.conf" 2>/dev/null
# sda1 armbianEnv.txt rootdev 同步
sed -i "s|rootdev=UUID=[0-9a-f-]*|rootdev=UUID=$NEWROOT|g" "$MNT_BT/armbianEnv.txt" 2>/dev/null
log "sda1 引导配置已更新 (root=$NEWROOT, emmc恢复=$EMMC_UUID)"

# sda2 fstab: root 行更新 + /boot 指向 eMMC boot
sed -i "s|UUID=5bc79f04-f7ff-4649-ab20-d87809a52e5f|UUID=$NEWROOT|g" "$MNT_TGT/etc/fstab"
sed -i "s|UUID=[0-9a-f-]*  /boot|UUID=$EMMC_BOOT_UUID  /boot|g" "$MNT_TGT/etc/fstab"
log "fstab 已更新 (root=$NEWROOT, /boot->eMMC $EMMC_BOOT_UUID)"
# 同步 bootmgr 到 SATA rootfs (保证 SATA 系统里的 WebUI 也是最新版)
if [ -d /opt/bootmgr ] && [ -d "$MNT_TGT/opt/bootmgr" ]; then
  cp /opt/bootmgr/bootmgr.py /opt/bootmgr/clone.sh "$MNT_TGT/opt/bootmgr/" 2>/dev/null
  log "bootmgr 已同步到 SATA rootfs"
fi
# 清理临时挂载点目录
rmdir "$MNT_TGT/run/bootmgr_clone_root" "$MNT_TGT/run/bootmgr_clone_boot" 2>/dev/null || true
umount "$MNT_BT" 2>/dev/null
umount "$MNT_TGT" 2>/dev/null
log "已卸载并清理"

# ---------- 切换启动目标到 SATA ----------
step "switch" 97
fw_setenv bootdev sata
BD=$(fw_printenv bootdev 2>/dev/null)
log "bootdev -> $BD"
if ! echo "$BD" | grep -q "^bootdev=sata"; then
  log "ERROR: 切换 bootdev 失败"; echo "ERROR=switch-failed" >> "$STATE"; exit 1
fi

# ---------- 同步 eMMC 侧 extlinux.conf (日常默认指向 SATA rootfs) ----------
EMMC_BOOT=/boot
if [ -f "$EMMC_BOOT/extlinux/extlinux.conf" ]; then
  sed -i "s|root=UUID=[0-9a-f-]*|root=UUID=$NEWROOT|g" "$EMMC_BOOT/extlinux/extlinux.conf"
  log "eMMC extlinux.conf root -> UUID=$NEWROOT (日常默认 SATA)"
  # 确保 eMMC 有恢复配置
  if [ ! -f "$EMMC_BOOT/extlinux/extlinux-emmc.conf" ]; then
    cp "$EMMC_BOOT/extlinux/extlinux.conf" "$EMMC_BOOT/extlinux/extlinux-emmc.conf" 2>/dev/null
    sed -i "s|root=UUID=[0-9a-f-]*|root=UUID=$EMMC_UUID|g" "$EMMC_BOOT/extlinux/extlinux-emmc.conf"
    log "eMMC extlinux-emmc.conf root -> UUID=$EMMC_UUID (恢复)"
  fi
  # armbianEnv.txt rootdev 同步
  sed -i "s|rootdev=UUID=[0-9a-f-]*|rootdev=UUID=$NEWROOT|g" "$EMMC_BOOT/armbianEnv.txt" 2>/dev/null
  log "eMMC armbianEnv.txt rootdev -> UUID=$NEWROOT"
fi

step "done" 100
log "✅ 克隆完成! bootdev=sata, 下次重启将从 SATA 启动"
echo "DONE=1" >> "$STATE"
