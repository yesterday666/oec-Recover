# BootMgr — eMMC/SATA 双系统启动管理器 (RK3566 Armbian)

WebUI 控制 RK3566 盒子在 **eMMC（恢复系统）** 与 **SATA（日常系统）** 之间切换启动，
并支持**一键克隆** eMMC 系统到 SATA 盘（rsync 文件级，只拷贝实际数据）与**一键恢复**。

```
┌─ WebUI (Python :8080, systemd 自启) ──────────────────────┐
│  ● 状态区: 当前启动介质 / root 设备 / bootdev / SATA 状态  │
│  ● 操作区: [切到SATA启动] [切到eMMC启动]                  │
│            [克隆eMMC→SATA] [一键恢复SATA] [重启]          │
│  ● 实时进度条 + 日志窗口                                  │
└───────────────────────────────────────────────────────────┘
```

## 架构原理

```
U-Boot (eMMC 引导) → 内核/initrd (eMMC /boot) → root=UUID → 目标 rootfs
    bootdev=sata  → extlinux/extlinux.conf        → SATA rootfs (日常)
    bootdev=emmc  → extlinux/extlinux-emmc.conf   → eMMC rootfs (恢复)
```

- U-Boot 始终从 eMMC 加载内核/initrd/dtb（本机 U-Boot 的 SATA 驱动不可用，无法直接 SATA 引导）
- rootfs 通过 U-Boot 环境变量 `bootdev` 在 eMMC/SATA 之间切换
- 内核与 `/boot` 分区共享 eMMC（内核更新统一写 eMMC，U-Boot 总能读到）
- SATA 盘缺失/损坏时，切 `bootdev=emmc` 即进入恢复系统

## 快速开始

### 方式一：在线一键安装（推荐）

在盒子上执行一条命令，自动从 GitHub 拉取仓库并部署：

```bash
curl -sSL https://raw.githubusercontent.com/yesterday666/oec-Recover/main/install.sh | sudo bash
```

安装完成后浏览器访问: `http://<盒子IP>:8080`

### 方式二：本地部署

下载仓库到盒子后：

```bash
sudo bash deploy.sh
```

`deploy.sh` 自动完成：安装依赖 → 部署 `/opt/bootmgr` → systemd 自启 →
备份 U-Boot env → 注入 bootcmd 的 bootdev 逻辑 → 生成 extlinux 双配置。可重复执行。

## 文件说明

| 文件 | 作用 |
|---|---|
| `install.sh` | 在线一键安装（拉取仓库 → 自动部署） |
| `bootmgr.py` | WebUI 服务（Python 标准库，零依赖，端口 8080） |
| `clone.sh` | 克隆流水线（rsync 文件级克隆 + UUID 生成 + 配置修复 + 切 bootdev） |
| `deploy.sh` | 部署脚本（依赖、systemd、env 备份、bootcmd 注入） |
| `bootmgr.service` | systemd 单元（deploy.sh 自动生成） |

## API

- `GET /api/status` — 系统状态（当前介质/bootdev/SATA 状态）
- `POST /api/switch?target=sata|emmc[&reboot=1]` — 切换启动目标
- `POST /api/clone?force=0|1` — 启动克隆（force=1 格式化已有 SATA 系统，一键恢复）
- `GET /api/progress` — 克隆进度与日志
- `POST /api/reboot` — 重启

## 克隆流程（clone.sh）

```
1. 校验: 必须在 eMMC 系统执行; sda 存在; 无分区或 --force
2. sgdisk 重建 GPT: sda1=512M BOOT, sda2=剩余 ROOTFS
3. mkfs.ext4 格式化
4. rsync -aHAXx / → sda2   (只拷贝实际数据, 跳过虚拟文件系统)
5. rsync /boot → sda1
6. tune2fs 生成全新 UUID (双盘无冲突)
7. 修复 sda1/sda2 内引导配置 + fstab (/boot 指向 eMMC)
8. fw_setenv bootdev sata → 下次启动进 SATA 系统
```

## 安全与恢复

- **env 备份**: 每次部署自动备份 `/opt/bootmgr/env_backup_*.txt`
- **恢复系统**: `fw_setenv bootdev emmc` 重启即回 eMMC
- **克隆保护**: clone.sh 检测到当前在 SATA 系统会拒绝执行

## 已知限制

- 仅适用于 U-Boot 从 eMMC 引导的 RK3566 盒子（OPHub Armbian）
- 克隆必须在 eMMC 恢复系统执行
- SATA 口不向 3.5" 盘提供 12V 供电的盒子，需外部供电（SATA link down 现象）
