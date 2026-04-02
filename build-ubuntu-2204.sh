#!/bin/bash
# ============================================================
#  build-ubuntu-2204.sh
#  在 Debian/Ubuntu 宿主服务器上，通过 debootstrap + chroot
#  + penguins-eggs 构建 Ubuntu 22.04 Jammy 自定义 ISO
#
#  驱动安装策略：
#    Mellanox OFED (.tgz) — chroot 内指定目标内核头文件直接编译
#    NVIDIA (.run)        — chroot 内只装 userspace，.run 文件留在
#                          ISO 内，首次启动时自动编译内核模块
#
#  用法：sudo bash build-ubuntu-2204.sh
#  要求：宿主机为 Debian/Ubuntu，root 权限，磁盘 >= 30GB
# ============================================================
set -euo pipefail

# ╔══════════════════════════════════════════════════════════╗
# ║                ★ 配置区（按需修改）★                     ║
# ╚══════════════════════════════════════════════════════════╝

# ── ISO 基础信息 ──
ISO_BASENAME="ubuntu-22.04-custom"
ISO_COMPRESSION="--max"          # --max（小/慢） 或 留空（快/大）

# ── Live 系统账户 ──
LIVE_USER="ubuntu"
LIVE_USER_PASSWD="2jx4krv5fpcuuzxc"
LIVE_ROOT_PASSWD="2jx4krv5fpcuuzxc"

# ── 目录 ──
CHROOT_DIR="/mnt/chroot-ubuntu2204"   # chroot 工作目录，需约 25GB
OUTPUT_DIR="/home/isobuild"           # ISO 最终输出目录

# ── 本地驱动文件目录 ──
# 将下载好的驱动文件放到这个目录下，脚本会自动识别
DRIVERS_DIR="/opt/drivers"

# ── Mellanox OFED 驱动文件名（.tgz） ──
# 示例：MLNX_OFED_LINUX-24.10-1.1.4.0-ubuntu22.04-x86_64.tgz
# 留空则跳过安装
MLNX_OFED_TGZ="MLNX_OFED_LINUX-24.10-4.1.4.0-ubuntu24.04-x86_64.tgz"     # ← 填写你的文件名，例如 "MLNX_OFED_LINUX-24.10-1.1.4.0-ubuntu22.04-x86_64.tgz"

# ── NVIDIA 驱动文件名（.run） ──
# 示例：NVIDIA-Linux-x86_64-550.144.run
# 留空则跳过安装
NVIDIA_RUN="NVIDIA-Linux-x86_64-590.48.01.run"         # ← 填写你的文件名，例如 "NVIDIA-Linux-x86_64-550.144.run"

# ── 启动模式（uefi / bios）──
# uefi：现代服务器、虚拟机（KVM/VMware/Proxmox）推荐
# bios：老旧硬件或明确使用 Legacy 启动的机器
BOOT_MODE="uefi"

# ── 镜像源（清华 TUNA；境外服务器改为 archive.ubuntu.com）──
UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"

# ── 预装软件包 ──
EXTRA_PACKAGES=(
  vim curl wget git
  net-tools iproute2
  sudo bash-completion
  openssh-server
  htop rsync unzip zip
  linux-firmware ipmitool 
)

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

# ── 检查 root ──
[[ $EUID -ne 0 ]] && { log_error "请以 root 权限运行：sudo bash $0"; exit 1; }

START_TIME=$(date +%s)

# ── 退出时自动卸载 ──
cleanup() {
  echo ""; log_info "清理：卸载虚拟文件系统..."
  for fs in dev/pts dev proc sys; do
    umount "${CHROOT_DIR}/${fs}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ══════════════════════════════════════════
log_step "第 1 步：检查环境 & 验证驱动文件"
# ══════════════════════════════════════════

# 磁盘空间检查
AVAILABLE_GB=$(( $(df -k "$(dirname "${CHROOT_DIR}")" | awk 'NR==2{print $4}') / 1024 / 1024 ))
log_info "可用磁盘空间：${AVAILABLE_GB}GB"
[[ ${AVAILABLE_GB} -lt 20 ]] && { log_error "磁盘空间不足，至少需要 20GB"; exit 1; }

# 驱动文件验证
if [[ -n "${MLNX_OFED_TGZ}" ]]; then
  MLNX_OFED_PATH="${DRIVERS_DIR}/${MLNX_OFED_TGZ}"
  if [[ ! -f "${MLNX_OFED_PATH}" ]]; then
    log_error "Mellanox OFED 文件不存在：${MLNX_OFED_PATH}"
    log_error "请将 .tgz 文件放到 ${DRIVERS_DIR}/ 并修改脚本顶部 MLNX_OFED_TGZ 变量"
    exit 1
  fi
  log_ok "Mellanox OFED：$(basename "${MLNX_OFED_PATH}") ($(du -sh "${MLNX_OFED_PATH}" | cut -f1))"
else
  log_warn "MLNX_OFED_TGZ 未设置，跳过 Mellanox 驱动安装"
fi

if [[ -n "${NVIDIA_RUN}" ]]; then
  NVIDIA_RUN_PATH="${DRIVERS_DIR}/${NVIDIA_RUN}"
  if [[ ! -f "${NVIDIA_RUN_PATH}" ]]; then
    log_error "NVIDIA 驱动文件不存在：${NVIDIA_RUN_PATH}"
    log_error "请将 .run 文件放到 ${DRIVERS_DIR}/ 并修改脚本顶部 NVIDIA_RUN 变量"
    exit 1
  fi
  log_ok "NVIDIA 驱动：$(basename "${NVIDIA_RUN_PATH}") ($(du -sh "${NVIDIA_RUN_PATH}" | cut -f1))"
else
  log_warn "NVIDIA_RUN 未设置，跳过 NVIDIA 驱动安装"
fi

# 验证 BOOT_MODE
[[ "${BOOT_MODE}" =~ ^(uefi|bios)$ ]] || { log_error "BOOT_MODE 只能设为 uefi 或 bios"; exit 1; }
log_info "启动模式：${BOOT_MODE^^}"

# 安装宿主机依赖
log_info "安装宿主机依赖工具..."
apt-get update -q
apt-get install -y -q \
  debootstrap squashfs-tools xorriso \
  grub-efi-amd64-bin grub-pc-bin \
  mtools dosfstools curl gpg
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
log_step "第 4 步：chroot 内 —— 配置系统 & 安装基础软件"
# ══════════════════════════════════════════

PACKAGES_STR="${EXTRA_PACKAGES[*]}"
log_info "安装基础环境（约 10～20 分钟）..."

chroot "${CHROOT_DIR}" /bin/bash -s << CHROOT_BASE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
BOOT_MODE="${BOOT_MODE}"

echo "▸ 配置软件源..."
cat > /etc/apt/sources.list << 'SOURCES'
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu jammy-security main restricted universe multiverse
SOURCES
apt-get update -q

echo "▸ 安装内核（linux-image-generic + headers）..."
apt-get install -y -q \
  linux-image-generic linux-headers-generic \
  systemd-sysv init \
  locales tzdata

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
sed -i '/^#.*zh_CN.UTF-8/s/^#//' /etc/locale.gen 2>/dev/null || echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen 2>/dev/null || true

echo "▸ 安装预装软件包..."
apt-get install -y -q ${PACKAGES_STR}

echo "▸ 安装编译工具链（驱动依赖）..."
apt-get install -y -q \
  dkms build-essential gcc make perl \
  linux-headers-generic pkg-config \
  libelf-dev libssl-dev

echo "▸ 安装 Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null
apt-get install -y -q nodejs
echo "Node.js：\$(node --version)"

echo "▸ 安装 penguins-eggs..."
curl -fsSL https://pieroproietti.github.io/penguins-eggs-ppa/KEY.asc \
  | gpg --dearmor -o /usr/share/keyrings/penguins-eggs.gpg 2>/dev/null
echo "deb [signed-by=/usr/share/keyrings/penguins-eggs.gpg] \
https://pieroproietti.github.io/penguins-eggs-ppa ./" \
  > /etc/apt/sources.list.d/penguins-eggs.list
apt-get update -q
apt-get install -y penguins-eggs
echo "penguins-eggs：\$(eggs --version 2>/dev/null || echo '获取失败')"

CHROOT_BASE

log_ok "基础系统就绪。"

# ══════════════════════════════════════════
log_step "第 5 步：安装 Mellanox OFED 驱动（本地 .tgz）"
# ══════════════════════════════════════════

if [[ -n "${MLNX_OFED_TGZ}" ]]; then

  log_info "复制 OFED tgz 到 chroot..."
  mkdir -p "${CHROOT_DIR}/tmp/ofed"
  cp "${DRIVERS_DIR}/${MLNX_OFED_TGZ}" "${CHROOT_DIR}/tmp/ofed/"

  chroot "${CHROOT_DIR}" /bin/bash -s << CHROOT_MLNX
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 获取目标内核版本（chroot 内安装的内核）
TARGET_KERNEL=\$(ls /usr/src/ \
  | grep "linux-headers-" \
  | grep -v "generic\$" \
  | grep -v "\.d\$" \
  | sort -V | tail -1 \
  | sed 's/linux-headers-//')

if [[ -z "\${TARGET_KERNEL}" ]]; then
  # 兜底：用 generic 符号链接对应的真实版本
  TARGET_KERNEL=\$(ls /usr/src/ \
    | grep "linux-headers-" \
    | grep -v "\.d\$" \
    | sort -V | head -1 \
    | sed 's/linux-headers-//')
fi

echo "▸ 目标内核版本：\${TARGET_KERNEL}"
echo "▸ 解压 OFED 压缩包..."
tar xzf /tmp/ofed/${MLNX_OFED_TGZ} -C /tmp/ofed/

OFED_DIR=\$(find /tmp/ofed -maxdepth 1 -type d -name "MLNX_OFED*" | head -1)
if [[ -z "\${OFED_DIR}" ]]; then
  echo "[ERROR] 解压后未找到 MLNX_OFED 目录"
  exit 1
fi

echo "▸ 安装 OFED 依赖..."
# mlnxofedinstall 需要这些包
apt-get install -y -q \
  python3 python3-distutils \
  ethtool lsof \
  tk tcl libglib2.0-0 \
  pciutils numactl libnuma1 2>/dev/null || true

echo "▸ 运行 mlnxofedinstall（指定目标内核，约 5～15 分钟）..."
# 关键参数说明：
#   --without-fw-update   跳过固件升级（chroot 无法访问硬件）
#   --add-kernel-support  针对指定内核编译 DKMS 模块
#   --kernel              指定目标内核版本（避免与宿主机 uname -r 混淆）
#   --kernel-sources      指定内核头文件路径
#   --force               忽略版本检查冲突
#   --tmpdir              临时目录（避免 /tmp 空间不足）

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
  echo "[WARN] OFED 完整安装失败，尝试仅安装用户空间组件..."
  "\${OFED_DIR}/mlnxofedinstall" \
    --without-fw-update \
    --without-dkms \
    --user-space-only \
    --force \
    2>&1 | tee -a /var/log/mlnx-ofed-install.log \
  || echo "[WARN] 用户空间安装也失败，请检查 /var/log/mlnx-ofed-install.log"
}

echo "▸ 配置首次启动补全编译服务（以防内核模块未编译成功）..."
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
  echo "检查 Mellanox OFED 模块（内核 ${KERNEL}）..." && \
  if ! modinfo mlx5_core &>/dev/null; then \
    echo "模块未加载，执行 DKMS 编译..." && \
    dkms autoinstall -k ${KERNEL} 2>&1 | tee /var/log/mlnx-ofed-firstboot.log && \
    touch /var/lib/.mlnx-ofed-compiled && \
    echo "编译完成"; \
  else \
    echo "模块已就绪，无需重新编译" && \
    touch /var/lib/.mlnx-ofed-compiled; \
  fi'

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable mlnx-ofed-firstboot.service 2>/dev/null || true

echo "▸ 清理 OFED 安装临时文件..."
rm -rf /tmp/ofed /tmp/ofed-build

echo "✓ Mellanox OFED 安装完成"
CHROOT_MLNX

  log_ok "Mellanox OFED 安装完成。"
else
  log_info "跳过 Mellanox OFED（MLNX_OFED_TGZ 未设置）。"
fi

# ══════════════════════════════════════════
log_step "第 6 步：安装 NVIDIA 驱动（本地 .run）"
# ══════════════════════════════════════════

if [[ -n "${NVIDIA_RUN}" ]]; then

  log_info "复制 NVIDIA .run 到 chroot（文件将保留在 ISO 内供首次启动使用）..."
  # /opt/nvidia/ 会被打包进 squashfs，首次启动时用来编译内核模块
  mkdir -p "${CHROOT_DIR}/opt/nvidia"
  cp "${DRIVERS_DIR}/${NVIDIA_RUN}" "${CHROOT_DIR}/opt/nvidia/"
  chmod +x "${CHROOT_DIR}/opt/nvidia/${NVIDIA_RUN}"

  chroot "${CHROOT_DIR}" /bin/bash -s << CHROOT_NVIDIA
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NVIDIA_INSTALLER=\$(ls /opt/nvidia/NVIDIA-Linux-x86_64-*.run 2>/dev/null | head -1)
if [[ -z "\${NVIDIA_INSTALLER}" ]]; then
  echo "[ERROR] /opt/nvidia/ 中未找到 .run 文件"
  exit 1
fi
echo "▸ 使用安装文件：\$(basename \${NVIDIA_INSTALLER})"

echo "▸ 禁用 Nouveau 开源驱动..."
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'BEOF'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
BEOF

# 更新 initramfs 以使 nouveau 黑名单生效（chroot 内可能报警告，忽略即可）
update-initramfs -u 2>/dev/null || true

echo "▸ 安装 NVIDIA 驱动 userspace 组件（跳过内核模块编译）..."
# --no-kernel-module     不编译内核模块（chroot 内 uname -r 是宿主内核，无法编译目标内核模块）
# --ui=none              非交互模式
# --no-questions         全部使用默认值
# --accept-license       自动接受许可证
# --install-libglvnd     安装 libglvnd（推荐，兼容 OpenGL 分发层）
"\${NVIDIA_INSTALLER}" \
  --no-kernel-module \
  --ui=none \
  --no-questions \
  --accept-license \
  --install-libglvnd \
  2>&1 | tee /var/log/nvidia-userspace-install.log \
|| echo "[WARN] userspace 安装出现警告，请查看 /var/log/nvidia-userspace-install.log"

echo "▸ 配置首次启动内核模块编译服务..."
# .run 文件已保留在 /opt/nvidia/，首次启动时用 --kernel-module-only 编译
NVIDIA_RUN_BASENAME=\$(basename "\${NVIDIA_INSTALLER}")
cat > /etc/systemd/system/nvidia-driver-firstboot.service << SVCEOF
[Unit]
Description=NVIDIA Driver Kernel Module First-Boot Compilation
After=local-fs.target mlnx-ofed-firstboot.service
ConditionPathExists=!/var/lib/.nvidia-compiled

[Service]
Type=oneshot
RemainAfterExit=yes
# 超时设置长一些，编译可能需要 5～15 分钟
TimeoutStartSec=1800
ExecStart=/bin/bash -c '\
  KERNEL=\$(uname -r) && \
  echo "首次启动：编译 NVIDIA 内核模块（内核 \${KERNEL}）..." && \
  /opt/nvidia/${NVIDIA_RUN_BASENAME} \
    --silent \
    --kernel-module-only \
    --no-nouveau-check \
    2>&1 | tee /var/log/nvidia-firstboot.log && \
  depmod -a && \
  update-initramfs -u -k \${KERNEL} 2>&1 | tee -a /var/log/nvidia-firstboot.log && \
  touch /var/lib/.nvidia-compiled && \
  echo "NVIDIA 内核模块编译完成，下次重启后生效" \
  || echo "编译失败，请查看 /var/log/nvidia-firstboot.log"'

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable nvidia-driver-firstboot.service 2>/dev/null || true

echo "▸ 配置 nvidia-persistenced 持久化服务（可选，需要首次启动后）..."
cat > /etc/systemd/system/nvidia-persistenced.service << 'PEOF'
[Unit]
Description=NVIDIA Persistence Daemon
After=nvidia-driver-firstboot.service
ConditionPathExists=/var/lib/.nvidia-compiled

[Service]
Type=forking
ExecStart=/usr/bin/nvidia-persistenced --verbose
ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced
Restart=on-failure

[Install]
WantedBy=multi-user.target
PEOF
systemctl enable nvidia-persistenced.service 2>/dev/null || true

echo "✓ NVIDIA 驱动 userspace 已安装，内核模块将在 ISO 首次启动时编译"
echo "  安装文件保留位置：/opt/nvidia/\$(basename \${NVIDIA_INSTALLER})"

CHROOT_NVIDIA

  log_ok "NVIDIA 驱动安装完成（.run 文件已保留在 ISO 内）。"
else
  log_info "跳过 NVIDIA 驱动（NVIDIA_RUN 未设置）。"
fi

# ══════════════════════════════════════════
log_step "第 7 步：清理缓存 & 配置 eggs"
# ══════════════════════════════════════════

log_info "清理 apt 缓存..."
chroot "${CHROOT_DIR}" /bin/bash << 'CLEAN'
export DEBIAN_FRONTEND=noninteractive
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
# 清理 DKMS 编译产物（源码和注册信息保留）
find /var/lib/dkms -name "*.ko" -delete 2>/dev/null || true
find /var/lib/dkms -type d -name "build" -exec rm -rf {} + 2>/dev/null || true
CLEAN

log_info "初始化 eggs 配置..."
chroot "${CHROOT_DIR}" /bin/bash -c "eggs config --nointeractive 2>/dev/null || true"

EGGS_YAML="${CHROOT_DIR}/etc/penguins-eggs.d/eggs.yaml"
if [[ -f "${EGGS_YAML}" ]]; then
  log_info "更新 eggs.yaml..."
  python3 - << PYEOF
import re
path = '${EGGS_YAML}'
with open(path) as f:
    c = f.read()
rules = [
    (r'^(snapshot_basename\s*:\s*).*$', r'\g<1>${ISO_BASENAME}'),
    (r'^(snapshot_prefix\s*:\s*).*$',   r'\g<1>'),
    (r'^(user_opt\s*:\s*).*$',          r'\g<1>${LIVE_USER}'),
    (r'^(user_opt_passwd\s*:\s*).*$',   r'\g<1>${LIVE_USER_PASSWD}'),
    (r'^(root_passwd\s*:\s*).*$',       r'\g<1>${LIVE_ROOT_PASSWD}'),
]
for pat, repl in rules:
    c = re.sub(pat, repl, c, flags=re.MULTILINE)
with open(path, 'w') as f:
    f.write(c)
print("eggs.yaml 写入成功")
PYEOF
else
  log_warn "未找到 eggs.yaml，使用默认配置。"
fi
log_ok "eggs 配置完成。"

# ══════════════════════════════════════════
log_step "第 8 步：制作 ISO"
# ══════════════════════════════════════════

mkdir -p "${CHROOT_DIR}/home/eggs"
log_info "eggs produce 中（约 15～50 分钟）..."
chroot "${CHROOT_DIR}" /bin/bash -c \
  "mkdir -p /home/eggs && eggs produce --basename '${ISO_BASENAME}' ${ISO_COMPRESSION} --nointeractive"

# ══════════════════════════════════════════
log_step "第 9 步：复制 ISO 到输出目录"
# ══════════════════════════════════════════

mkdir -p "${OUTPUT_DIR}"
shopt -s nullglob
ISO_FILES=( "${CHROOT_DIR}/home/eggs/"*.iso )
shopt -u nullglob

[[ ${#ISO_FILES[@]} -eq 0 ]] && { log_error "未找到 ISO 文件，请检查上方日志"; exit 1; }

for iso in "${ISO_FILES[@]}"; do
  cp "${iso}" "${OUTPUT_DIR}/"
  log_ok "输出：${OUTPUT_DIR}/$(basename "${iso}")"
done

# ══════════════════════════════════════════
# 完成报告
# ══════════════════════════════════════════

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔════════════════════════════════════════════════╗"
echo "  ║              ✅  ISO 构建成功！                ║"
echo "  ╚════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${BOLD}总耗时：${RESET}$(( ELAPSED/60 )) 分 $(( ELAPSED%60 )) 秒"
echo ""
echo -e "  ${BOLD}输出文件：${RESET}"
ls -lh "${OUTPUT_DIR}/"*.iso 2>/dev/null | awk '{printf "    %-10s  %s\n", $5, $9}'
echo ""
echo -e "  ${BOLD}Live 账户：${RESET}${LIVE_USER} / ${LIVE_USER_PASSWD}"
echo -e "  ${BOLD}Root 密码：${RESET}${LIVE_ROOT_PASSWD}"
echo ""
echo -e "  ${BOLD}驱动使用说明：${RESET}"
if [[ -n "${MLNX_OFED_TGZ}" ]]; then
  echo -e "  ${YELLOW}[Mellanox OFED]${RESET}"
  echo    "    · 内核模块已在构建时编译（mlnxofedinstall --add-kernel-support）"
  echo    "    · 若首次启动发现模块未加载，mlnx-ofed-firstboot.service 会自动补编"
  echo    "    · 安装日志：/var/log/mlnx-ofed-install.log"
fi
if [[ -n "${NVIDIA_RUN}" ]]; then
  echo -e "  ${YELLOW}[NVIDIA 驱动]${RESET}"
  echo    "    · Userspace 组件已安装（libGL、nvidia-smi 等可直接使用）"
  echo    "    · 内核模块：首次启动时由 nvidia-driver-firstboot.service 自动编译"
  echo    "    · 编译完成后需要重启一次，驱动才正式生效"
  echo    "    · 安装文件保留在：/opt/nvidia/${NVIDIA_RUN}"
  echo    "    · 编译日志：/var/log/nvidia-firstboot.log"
fi
echo ""
echo -e "  ${BOLD}首次启动流程：${RESET}"
echo    "    启动 ISO → 登录系统 → 等待 systemd 服务自动编译驱动（约 5～15 分钟）"
echo    "    → 重启 → 驱动加载完成"
echo ""
echo -e "  ${BOLD}验证驱动（重启后）：${RESET}"
[[ -n "${MLNX_OFED_TGZ}" ]] && echo "    ibv_devinfo          # 验证 Mellanox 网卡"
[[ -n "${NVIDIA_RUN}" ]]    && echo "    nvidia-smi           # 验证 NVIDIA GPU"
echo ""
