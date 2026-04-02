#!/bin/bash
# ============================================================
#  build-ubuntu-2204-subiquity.sh
#
#  构建流程：
#    1. debootstrap + chroot 构建自定义根文件系统
#    2. 安装 Mellanox OFED / NVIDIA 驱动
#    3. 打包为 squashfs
#    4. 注入 Ubuntu 22.04 Server ISO（替换官方 squashfs）
#    5. （可选）嵌入 autoinstall user-data，实现全自动安装
#    6. 用 xorriso 重新封装为可启动 ISO
#
#  安装器：Ubuntu 官方 Subiquity（支持 autoinstall YAML）
#  用法：sudo bash build-ubuntu-2204-subiquity.sh
#  要求：Debian/Ubuntu 宿主机，root 权限，磁盘 >= 40GB
# ============================================================
set -euo pipefail

# ╔══════════════════════════════════════════════════════════╗
# ║                ★ 配置区（按需修改）★                     ║
# ╚══════════════════════════════════════════════════════════╝

# ── ISO 信息 ──
ISO_BASENAME="ubuntu-22.04-custom"

# ── 启动模式 ──
# uefi：现代服务器 / KVM / VMware / Proxmox（推荐）
# bios：老旧硬件或 Legacy 启动
BOOT_MODE="uefi"

# ── Live 系统账户（live 环境临时用，不影响安装后的系统）──
LIVE_USER="ubuntu"
LIVE_USER_PASSWD="live"
LIVE_ROOT_PASSWD="live"

# ── 目录 ──
CHROOT_DIR="/mnt/chroot-ubuntu2204"
WORK_DIR="/tmp/iso-work"           # ISO 解包目录
OUTPUT_DIR="/home/isobuild"        # 最终 ISO 输出目录

# ── Ubuntu 22.04 Server ISO（Subiquity 安装器来源）──
# 如果文件不存在，脚本会自动下载
UBUNTU_ISO_PATH="/opt/ubuntu-22.04-live-server-amd64.iso"
UBUNTU_ISO_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/ubuntu-22.04.5-live-server-amd64.iso"

# ── 镜像源 ──
UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"

# ── 本地驱动文件目录 ──
DRIVERS_DIR="/opt/drivers"

# ── Mellanox OFED（.tgz，留空跳过）──
MLNX_OFED_TGZ=""
# 示例：MLNX_OFED_TGZ="MLNX_OFED_LINUX-24.10-1.1.4.0-ubuntu22.04-x86_64.tgz"

# ── NVIDIA 驱动（.run，留空跳过）──
NVIDIA_RUN=""
# 示例：NVIDIA_RUN="NVIDIA-Linux-x86_64-550.144.run"

# ── 预装软件包 ──
EXTRA_PACKAGES=(
  vim curl wget git
  net-tools iproute2
  sudo bash-completion
  openssh-server
  htop rsync unzip zip
  linux-firmware ipmitool
)

# ── 嵌入 autoinstall user-data（true 开启，false 关闭）──
# 开启后 ISO 启动即自动安装，无需任何交互
EMBED_AUTOINSTALL="false"

# ── autoinstall 目标磁盘（EMBED_AUTOINSTALL=true 时生效）──
# 留空则自动选择最大磁盘
AUTOINSTALL_DISK=""
# 示例：AUTOINSTALL_DISK="/dev/sda"

# ── autoinstall 安装后账户 ──
INSTALL_USERNAME="ubuntu"
INSTALL_PASSWORD_HASH='$6$rounds=4096$customsalt$V8tFMDPLjhHlMO3FmNnkMJa0YF8L6pBbT.YKrE3Xh2e5fETMWdIx0oqKXa2u9SYZ7eLALF.I2uBLzMJzUDkx1'
# 用 openssl passwd -6 生成：openssl passwd -6 "你的密码"
INSTALL_HOSTNAME="ubuntu-server"

# ── autoinstall SSH 公钥（可留空）──
INSTALL_SSH_PUBKEY=""
# 示例：INSTALL_SSH_PUBKEY="ssh-rsa AAAA..."

# ╔══════════════════════════════════════════════════════════╗
# ║                脚本主体（无需修改）                       ║
# ╚══════════════════════════════════════════════════════════╝

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
log_step()  { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }

[[ $EUID -ne 0 ]] && { log_error "请以 root 权限运行：sudo bash $0"; exit 1; }
[[ "${BOOT_MODE}" =~ ^(uefi|bios)$ ]] || { log_error "BOOT_MODE 只能设为 uefi 或 bios"; exit 1; }

START_TIME=$(date +%s)

# ── 退出清理 ──
cleanup() {
  echo ""; log_info "清理：卸载虚拟文件系统..."
  for fs in dev/pts dev proc sys; do
    umount "${CHROOT_DIR}/${fs}" 2>/dev/null || true
  done
  # 卸载 ISO 挂载点
  umount /mnt/ubuntu-iso 2>/dev/null || true
}
trap cleanup EXIT

# ══════════════════════════════════════════
log_step "第 1 步：检查环境 & 验证文件"
# ══════════════════════════════════════════

AVAILABLE_GB=$(( $(df -k "$(dirname "${CHROOT_DIR}")" | awk 'NR==2{print $4}') / 1024 / 1024 ))
log_info "可用磁盘空间：${AVAILABLE_GB}GB"
[[ ${AVAILABLE_GB} -lt 30 ]] && { log_error "磁盘空间不足，至少需要 30GB"; exit 1; }

# 驱动文件验证
if [[ -n "${MLNX_OFED_TGZ}" ]]; then
  [[ ! -f "${DRIVERS_DIR}/${MLNX_OFED_TGZ}" ]] && {
    log_error "Mellanox OFED 文件不存在：${DRIVERS_DIR}/${MLNX_OFED_TGZ}"; exit 1; }
  log_ok "Mellanox OFED：${MLNX_OFED_TGZ} ($(du -sh "${DRIVERS_DIR}/${MLNX_OFED_TGZ}" | cut -f1))"
else
  log_warn "MLNX_OFED_TGZ 未设置，跳过 Mellanox 驱动"
fi

if [[ -n "${NVIDIA_RUN}" ]]; then
  [[ ! -f "${DRIVERS_DIR}/${NVIDIA_RUN}" ]] && {
    log_error "NVIDIA 驱动文件不存在：${DRIVERS_DIR}/${NVIDIA_RUN}"; exit 1; }
  log_ok "NVIDIA 驱动：${NVIDIA_RUN} ($(du -sh "${DRIVERS_DIR}/${NVIDIA_RUN}" | cut -f1))"
else
  log_warn "NVIDIA_RUN 未设置，跳过 NVIDIA 驱动"
fi

log_info "安装宿主机依赖工具..."
apt-get update -q
apt-get install -y -q \
  debootstrap squashfs-tools xorriso \
  grub-efi-amd64-bin grub-pc-bin \
  mtools dosfstools curl gpg isolinux
log_ok "宿主机工具就绪。"

# ══════════════════════════════════════════
log_step "第 2 步：debootstrap 创建 Ubuntu 22.04 基础系统"
# ══════════════════════════════════════════

if [[ -d "${CHROOT_DIR}" ]]; then
  log_warn "检测到旧目录 ${CHROOT_DIR}，清理中..."
  for fs in dev/pts dev proc sys; do umount "${CHROOT_DIR}/${fs}" 2>/dev/null || true; done
  rm -rf "${CHROOT_DIR}"
fi

log_info "debootstrap 中（约 5～15 分钟）..."
debootstrap \
  --arch=amd64 \
  --components=main,restricted,universe,multiverse \
  jammy "${CHROOT_DIR}" "${UBUNTU_MIRROR}"
log_ok "基础系统创建完成。"

# ══════════════════════════════════════════
log_step "第 3 步：挂载虚拟文件系统"
# ══════════════════════════════════════════

for fs in dev dev/pts proc sys; do mount --bind "/${fs}" "${CHROOT_DIR}/${fs}"; done
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"
log_ok "dev / dev/pts / proc / sys 挂载完成。"

# ══════════════════════════════════════════
log_step "第 4 步：chroot 内 —— 配置系统 & 安装软件"
# ══════════════════════════════════════════

PACKAGES_STR="${EXTRA_PACKAGES[*]}"

chroot "${CHROOT_DIR}" /bin/bash -s << CHROOT_BASE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
BOOT_MODE="${BOOT_MODE}"
LIVE_USER="${LIVE_USER}"
LIVE_USER_PASSWD="${LIVE_USER_PASSWD}"
LIVE_ROOT_PASSWD="${LIVE_ROOT_PASSWD}"

echo "▸ 配置软件源..."
cat > /etc/apt/sources.list << 'SOURCES'
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy-security main restricted universe multiverse
SOURCES
apt-get update -q

echo "▸ 安装内核..."
apt-get install -y -q \
  linux-image-generic linux-headers-generic \
  systemd-sysv init locales tzdata

echo "▸ 安装 GRUB（模式：${BOOT_MODE}）..."
if [[ "${BOOT_MODE}" == "uefi" ]]; then
  apt-get install -y -q grub-efi-amd64 grub-efi-amd64-signed shim-signed
else
  apt-get install -y -q grub-pc
fi

echo "▸ 配置时区和语言..."
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen 2>/dev/null || true

echo "▸ 安装预装软件包..."
apt-get install -y -q ${PACKAGES_STR}

echo "▸ 安装编译工具链（驱动依赖）..."
apt-get install -y -q \
  dkms build-essential gcc make perl \
  pkg-config libelf-dev libssl-dev

echo "▸ 安装 cloud-init（Subiquity 安装器依赖）..."
apt-get install -y -q cloud-init cloud-utils

echo "▸ 设置 Live 用户..."
useradd -m -s /bin/bash "${LIVE_USER}" 2>/dev/null || true
echo "${LIVE_USER}:${LIVE_USER_PASSWD}" | chpasswd
echo "root:${LIVE_ROOT_PASSWD}" | chpasswd
usermod -aG sudo "${LIVE_USER}"
echo "${LIVE_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/live-user

echo "▸ 配置网络（DHCP 自动适配所有网卡）..."
mkdir -p /etc/netplan
cat > /etc/netplan/00-installer-config.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      optional: true
NETPLAN
chmod 600 /etc/netplan/00-installer-config.yaml

echo "▸ 启用 SSH..."
systemctl enable ssh 2>/dev/null || true

CHROOT_BASE

log_ok "基础系统就绪。"

# ══════════════════════════════════════════
log_step "第 5 步：安装 Mellanox OFED 驱动"
# ══════════════════════════════════════════

if [[ -n "${MLNX_OFED_TGZ}" ]]; then
  log_info "复制 OFED tgz 到 chroot..."
  mkdir -p "${CHROOT_DIR}/tmp/ofed"
  cp "${DRIVERS_DIR}/${MLNX_OFED_TGZ}" "${CHROOT_DIR}/tmp/ofed/"

  chroot "${CHROOT_DIR}" /bin/bash -s << CHROOT_MLNX
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

TARGET_KERNEL=\$(ls /usr/src/ \
  | grep "linux-headers-" \
  | grep -v "generic\$" \
  | grep -v "\.d\$" \
  | sort -V | tail -1 \
  | sed 's/linux-headers-//')

[[ -z "\${TARGET_KERNEL}" ]] && \
  TARGET_KERNEL=\$(ls /usr/src/ | grep "linux-headers-" | grep -v "\.d\$" | sort -V | head -1 | sed 's/linux-headers-//')

echo "▸ 目标内核版本：\${TARGET_KERNEL}"
tar xzf /tmp/ofed/${MLNX_OFED_TGZ} -C /tmp/ofed/

OFED_DIR=\$(find /tmp/ofed -maxdepth 1 -type d -name "MLNX_OFED*" | head -1)
[[ -z "\${OFED_DIR}" ]] && { echo "[ERROR] 未找到 MLNX_OFED 目录"; exit 1; }

apt-get install -y -q \
  python3 python3-distutils ethtool lsof \
  tk tcl libglib2.0-0 pciutils numactl libnuma1 2>/dev/null || true

mkdir -p /tmp/ofed-build
"\${OFED_DIR}/mlnxofedinstall" \
  --without-fw-update \
  --add-kernel-support \
  --kernel "\${TARGET_KERNEL}" \
  --kernel-sources "/usr/src/linux-headers-\${TARGET_KERNEL}" \
  --force \
  --tmpdir /tmp/ofed-build \
  2>&1 | tee /var/log/mlnx-ofed-install.log \
|| {
  echo "[WARN] OFED 完整安装失败，尝试仅安装用户空间..."
  "\${OFED_DIR}/mlnxofedinstall" \
    --without-fw-update --without-dkms --user-space-only --force \
    2>&1 | tee -a /var/log/mlnx-ofed-install.log \
  || echo "[WARN] 用户空间安装也失败，请检查日志"
}

# 首次启动补编服务
cat > /etc/systemd/system/mlnx-ofed-firstboot.service << 'SVCEOF'
[Unit]
Description=Mellanox OFED DKMS First-Boot Compilation
After=local-fs.target
ConditionPathExists=!/var/lib/.mlnx-ofed-compiled

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  KERNEL=$(uname -r) && \
  if ! modinfo mlx5_core &>/dev/null; then \
    dkms autoinstall -k ${KERNEL} 2>&1 | tee /var/log/mlnx-ofed-firstboot.log && \
    touch /var/lib/.mlnx-ofed-compiled; \
  else \
    touch /var/lib/.mlnx-ofed-compiled; \
  fi'

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable mlnx-ofed-firstboot.service 2>/dev/null || true

rm -rf /tmp/ofed /tmp/ofed-build
echo "✓ Mellanox OFED 安装完成"
CHROOT_MLNX

  log_ok "Mellanox OFED 安装完成。"
else
  log_info "跳过 Mellanox OFED。"
fi

# ══════════════════════════════════════════
log_step "第 6 步：安装 NVIDIA 驱动（userspace）"
# ══════════════════════════════════════════

if [[ -n "${NVIDIA_RUN}" ]]; then
  mkdir -p "${CHROOT_DIR}/opt/nvidia"
  cp "${DRIVERS_DIR}/${NVIDIA_RUN}" "${CHROOT_DIR}/opt/nvidia/"
  chmod +x "${CHROOT_DIR}/opt/nvidia/${NVIDIA_RUN}"

  chroot "${CHROOT_DIR}" /bin/bash -s << CHROOT_NVIDIA
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NVIDIA_INSTALLER=\$(ls /opt/nvidia/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1)
[[ -z "\${NVIDIA_INSTALLER}" ]] && { echo "[ERROR] 未找到 .run 文件"; exit 1; }

cat > /etc/modprobe.d/blacklist-nouveau.conf << 'BEOF'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
BEOF
update-initramfs -u 2>/dev/null || true

"\${NVIDIA_INSTALLER}" \
  --no-kernel-module --ui=none --no-questions \
  --accept-license --install-libglvnd \
  2>&1 | tee /var/log/nvidia-userspace-install.log \
|| echo "[WARN] userspace 安装出现警告，请查看日志"

NVIDIA_RUN_BASENAME=\$(basename "\${NVIDIA_INSTALLER}")
cat > /etc/systemd/system/nvidia-driver-firstboot.service << SVCEOF
[Unit]
Description=NVIDIA Driver Kernel Module First-Boot Compilation
After=local-fs.target mlnx-ofed-firstboot.service
ConditionPathExists=!/var/lib/.nvidia-compiled

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=1800
ExecStart=/bin/bash -c '\
  KERNEL=\$(uname -r) && \
  /opt/nvidia/${NVIDIA_RUN_BASENAME} \
    --silent --kernel-module-only --no-nouveau-check \
    2>&1 | tee /var/log/nvidia-firstboot.log && \
  depmod -a && \
  update-initramfs -u -k \${KERNEL} && \
  touch /var/lib/.nvidia-compiled \
  || echo "编译失败，请查看 /var/log/nvidia-firstboot.log"'

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable nvidia-driver-firstboot.service 2>/dev/null || true

echo "✓ NVIDIA userspace 安装完成"
CHROOT_NVIDIA

  log_ok "NVIDIA 驱动安装完成。"
else
  log_info "跳过 NVIDIA 驱动。"
fi

# ══════════════════════════════════════════
log_step "第 7 步：清理 chroot"
# ══════════════════════════════════════════

chroot "${CHROOT_DIR}" /bin/bash << 'CLEAN'
export DEBIAN_FRONTEND=noninteractive
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -delete 2>/dev/null || true
CLEAN

# 卸载虚拟文件系统（后续 mksquashfs 不能有挂载点）
log_info "卸载虚拟文件系统..."
for fs in dev/pts dev proc sys; do
  umount "${CHROOT_DIR}/${fs}" 2>/dev/null || true
done
log_ok "chroot 清理完成。"

# ══════════════════════════════════════════
log_step "第 8 步：获取 Ubuntu 22.04 Server ISO"
# ══════════════════════════════════════════

if [[ ! -f "${UBUNTU_ISO_PATH}" ]]; then
  log_info "未找到本地 ISO，开始下载（约 1.5GB）..."
  log_info "下载地址：${UBUNTU_ISO_URL}"
  mkdir -p "$(dirname "${UBUNTU_ISO_PATH}")"
  curl -L --progress-bar "${UBUNTU_ISO_URL}" -o "${UBUNTU_ISO_PATH}"
  log_ok "ISO 下载完成：${UBUNTU_ISO_PATH}"
else
  log_ok "使用本地 ISO：${UBUNTU_ISO_PATH} ($(du -sh "${UBUNTU_ISO_PATH}" | cut -f1))"
fi

# ══════════════════════════════════════════
log_step "第 9 步：解包 Ubuntu Server ISO"
# ══════════════════════════════════════════

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

log_info "挂载并复制 ISO 内容..."
mkdir -p /mnt/ubuntu-iso
mount -o loop,ro "${UBUNTU_ISO_PATH}" /mnt/ubuntu-iso
cp -a /mnt/ubuntu-iso/. "${WORK_DIR}/"
umount /mnt/ubuntu-iso
chmod -R u+w "${WORK_DIR}"

log_ok "ISO 解包完成：${WORK_DIR}"

# ══════════════════════════════════════════
log_step "第 10 步：构建自定义 squashfs"
# ══════════════════════════════════════════

SQUASHFS_PATH="${WORK_DIR}/casper/filesystem.squashfs"

log_info "删除原始 squashfs..."
rm -f "${SQUASHFS_PATH}"

log_info "构建自定义 squashfs（约 10～30 分钟，取决于内容大小）..."
mksquashfs "${CHROOT_DIR}" "${SQUASHFS_PATH}" \
  -comp xz \
  -e boot \
  -noappend \
  -wildcards \
  -e "proc/*" \
  -e "sys/*" \
  -e "dev/*" \
  -e "tmp/*" \
  -e "run/*"

log_ok "squashfs 构建完成：$(du -sh "${SQUASHFS_PATH}" | cut -f1)"

# 更新 filesystem.size（安装器需要此文件估算磁盘用量）
printf "%s" "$(du -sx --block-size=1 "${CHROOT_DIR}" | cut -f1)" \
  > "${WORK_DIR}/casper/filesystem.size"

# 更新 filesystem.manifest（已安装软件包清单）
log_info "更新 filesystem.manifest..."
# 重新挂载 proc 用于 dpkg-query
mount --bind /proc "${CHROOT_DIR}/proc"
chroot "${CHROOT_DIR}" dpkg-query -W --showformat='${Package} ${Version}\n' \
  > "${WORK_DIR}/casper/filesystem.manifest" 2>/dev/null || true
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
log_ok "manifest 更新完成。"

# 更新 casper 内核（使用 chroot 内的内核）
log_info "更新 casper 内核文件..."
CHROOT_KERNEL=$(ls "${CHROOT_DIR}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
CHROOT_INITRD=$(ls "${CHROOT_DIR}/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1)

if [[ -f "${CHROOT_KERNEL}" && -f "${CHROOT_INITRD}" ]]; then
  cp "${CHROOT_KERNEL}" "${WORK_DIR}/casper/vmlinuz"
  cp "${CHROOT_INITRD}" "${WORK_DIR}/casper/initrd"
  log_ok "内核更新：$(basename "${CHROOT_KERNEL}")"
else
  log_warn "未找到 chroot 内核，保留原始 ISO 内核"
fi

# ══════════════════════════════════════════
log_step "第 11 步：配置 GRUB 引导"
# ══════════════════════════════════════════

GRUB_CFG="${WORK_DIR}/boot/grub/grub.cfg"

# 根据是否嵌入 autoinstall 生成 GRUB 配置
if [[ "${EMBED_AUTOINSTALL}" == "true" ]]; then
  KERNEL_PARAMS="quiet splash autoinstall ds=nocloud;s=/cdrom/autoinstall/"
  log_info "GRUB 配置：自动安装模式"
else
  KERNEL_PARAMS="quiet splash"
  log_info "GRUB 配置：交互式安装模式"
fi

cat > "${GRUB_CFG}" << GRUBEOF
set default=0
set timeout=5

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install Ubuntu 22.04 Custom Server" {
    set gfxpayload=keep
    linux   /casper/vmlinuz ${KERNEL_PARAMS} ---
    initrd  /casper/initrd
}

menuentry "Install Ubuntu 22.04 Custom Server (Safe Graphics)" {
    set gfxpayload=keep
    linux   /casper/vmlinuz ${KERNEL_PARAMS} nomodeset ---
    initrd  /casper/initrd
}
GRUBEOF

# 同步更新 isolinux（BIOS 引导）
if [[ -f "${WORK_DIR}/isolinux/txt.cfg" ]]; then
  cat > "${WORK_DIR}/isolinux/txt.cfg" << ISOLINUXEOF
default install
label install
  menu label ^Install Ubuntu 22.04 Custom Server
  kernel /casper/vmlinuz
  append initrd=/casper/initrd ${KERNEL_PARAMS} ---
ISOLINUXEOF
fi

log_ok "GRUB 引导配置完成。"

# ══════════════════════════════════════════
log_step "第 12 步：嵌入 autoinstall 配置（可选）"
# ══════════════════════════════════════════

if [[ "${EMBED_AUTOINSTALL}" == "true" ]]; then
  log_info "生成 autoinstall user-data..."
  mkdir -p "${WORK_DIR}/autoinstall"

  # 构建磁盘配置部分
  if [[ -n "${AUTOINSTALL_DISK}" ]]; then
    DISK_SELECTOR="    match:
        path: ${AUTOINSTALL_DISK}"
  else
    DISK_SELECTOR="    match:
        largest: true"
  fi

  # 构建 SSH 公钥部分
  if [[ -n "${INSTALL_SSH_PUBKEY}" ]]; then
    SSH_KEYS_SECTION="    authorized-keys:
      - \"${INSTALL_SSH_PUBKEY}\""
  else
    SSH_KEYS_SECTION="    authorized-keys: []"
  fi

  cat > "${WORK_DIR}/autoinstall/user-data" << USERDATA
#cloud-config
autoinstall:
  version: 1

  locale: zh_CN.UTF-8
  timezone: Asia/Shanghai
  keyboard:
    layout: us

  identity:
    hostname: ${INSTALL_HOSTNAME}
    username: ${INSTALL_USERNAME}
    password: "${INSTALL_PASSWORD_HASH}"
    realname: Server User

  ssh:
    install-server: true
    allow-pw: true
${SSH_KEYS_SECTION}

  # 分区方案：EFI(512MB) + /boot(4GB) + /(其余) ，无 swap
  storage:
    layout:
      name: custom
    config:
      - type: disk
        id: disk0
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
        grub_device: false
${DISK_SELECTOR}

      - type: partition
        id: part-efi
        device: disk0
        size: 512M
        flag: boot
        grub_device: true

      - type: partition
        id: part-boot
        device: disk0
        size: 4G

      - type: partition
        id: part-root
        device: disk0
        size: -1

      - type: format
        id: fmt-efi
        volume: part-efi
        fstype: fat32

      - type: format
        id: fmt-boot
        volume: part-boot
        fstype: ext4

      - type: format
        id: fmt-root
        volume: part-root
        fstype: ext4

      - type: mount
        id: mnt-efi
        device: fmt-efi
        path: /boot/efi

      - type: mount
        id: mnt-boot
        device: fmt-boot
        path: /boot

      - type: mount
        id: mnt-root
        device: fmt-root
        path: /

  network:
    version: 2
    ethernets:
      all-en:
        match:
          name: "en*"
        dhcp4: true
        optional: true
      all-eth:
        match:
          name: "eth*"
        dhcp4: true
        optional: true

  packages:
    - openssh-server

  late-commands:
    - echo '${INSTALL_USERNAME} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${INSTALL_USERNAME}
    - chmod 440 /target/etc/sudoers.d/${INSTALL_USERNAME}
    - curtin in-target --target=/target -- systemctl enable ssh

  shutdown: reboot
USERDATA

  # meta-data 必须存在（可为空）
  touch "${WORK_DIR}/autoinstall/meta-data"

  log_ok "autoinstall 配置生成完成：${WORK_DIR}/autoinstall/user-data"
else
  log_info "EMBED_AUTOINSTALL=false，跳过 autoinstall 配置。"
  log_info "如需自动安装，请设置 EMBED_AUTOINSTALL=true 后重新构建，"
  log_info "或启动 ISO 后在 GRUB 参数末尾手动添加："
  log_info "  autoinstall ds=nocloud-net;s=http://YOUR_SERVER/autoinstall/"
fi

# ══════════════════════════════════════════
log_step "第 13 步：重新封装 ISO"
# ══════════════════════════════════════════

mkdir -p "${OUTPUT_DIR}"
FINAL_ISO="${OUTPUT_DIR}/${ISO_BASENAME}.iso"
rm -f "${FINAL_ISO}"

log_info "封装 ISO 中（约 2～5 分钟）..."

# 提取 MBR 引导数据
MBR_IMG="${WORK_DIR}/boot/grub/i386-pc/boot_hybrid.img"

if [[ "${BOOT_MODE}" == "uefi" && -f "${MBR_IMG}" ]]; then
  # UEFI + Legacy 双模式
  xorriso -as mkisofs \
    -r \
    -V "Ubuntu 22.04 Custom" \
    -o "${FINAL_ISO}" \
    --grub2-mbr "${MBR_IMG}" \
    -partition_offset 16 \
    --mbr-force-bootable \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b \
      "${WORK_DIR}/boot/grub/efi.img" \
    -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot/grub/boot.cat' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
    -no-emul-boot \
    "${WORK_DIR}" 2>&1 | tail -5
else
  # BIOS only 或没有 hybrid 镜像时的兜底方案
  xorriso -as mkisofs \
    -r \
    -V "Ubuntu 22.04 Custom" \
    -o "${FINAL_ISO}" \
    -c '/boot/grub/boot.cat' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "${WORK_DIR}" 2>&1 | tail -5
fi

log_ok "ISO 封装完成。"

# ══════════════════════════════════════════
# 完成报告
# ══════════════════════════════════════════

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔════════════════════════════════════════════════════╗"
echo "  ║            ✅  ISO 构建成功！                      ║"
echo "  ╚════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${BOLD}总耗时：${RESET}$(( ELAPSED/60 )) 分 $(( ELAPSED%60 )) 秒"
echo ""
echo -e "  ${BOLD}输出文件：${RESET}"
ls -lh "${OUTPUT_DIR}/"*.iso 2>/dev/null | awk '{printf "    %-10s  %s\n", $5, $9}'
echo ""
echo -e "  ${BOLD}安装器：${RESET}Ubuntu Subiquity（官方）"
echo -e "  ${BOLD}启动模式：${RESET}${BOOT_MODE^^}"
echo ""
if [[ "${EMBED_AUTOINSTALL}" == "true" ]]; then
  echo -e "  ${BOLD}安装模式：${RESET}${RED}全自动（启动后无需任何交互，直接安装！）${RESET}"
  echo -e "  ${BOLD}目标磁盘：${RESET}${AUTOINSTALL_DISK:-自动选择最大磁盘}"
  echo -e "  ${BOLD}安装账户：${RESET}${INSTALL_USERNAME}"
  echo ""
  echo -e "  ${YELLOW}⚠  警告：ISO 启动后将自动格式化目标磁盘，请确认插入的是正确的服务器！${RESET}"
else
  echo -e "  ${BOLD}安装模式：${RESET}交互式（Subiquity 界面引导安装）"
  echo ""
  echo -e "  ${BOLD}若需全自动安装，设置：${RESET}EMBED_AUTOINSTALL=true"
fi
echo ""
echo -e "  ${BOLD}分区方案（autoinstall）：${RESET}"
echo    "    EFI    512MB  fat32"
echo    "    /boot  4GB    ext4"
echo    "    /      其余   ext4    无 swap"
echo ""
if [[ -n "${MLNX_OFED_TGZ}" ]]; then
  echo -e "  ${YELLOW}[Mellanox OFED]${RESET} 已预装，首次启动自动补编内核模块"
fi
if [[ -n "${NVIDIA_RUN}" ]]; then
  echo -e "  ${YELLOW}[NVIDIA 驱动]${RESET}   Userspace 已装，首次启动自动编译内核模块，需重启生效"
fi
echo ""
