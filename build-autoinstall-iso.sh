#!/bin/bash
# ============================================================
#  build-autoinstall-iso.sh
#
#  功能：将 user-data 嵌入 Ubuntu Server ISO，生成全自动安装盘
#
#  用法：sudo bash build-autoinstall-iso.sh
#  要求：Debian/Ubuntu 宿主机，root 权限，磁盘 >= 10GB
# ============================================================
set -euo pipefail

# ╔══════════════════════════════════════════════════════════╗
# ║                ★ 配置区（按需修改）★                     ║
# ╚══════════════════════════════════════════════════════════╝

# ── user-data 文件路径（你的 autoinstall 配置）──
USER_DATA_FILE="$(dirname "$0")/user-data"

# ── Ubuntu 22.04 Server ISO ──
# 如果本地已有，填写路径；否则脚本自动下载
UBUNTU_ISO_PATH="/opt/ubuntu-22.04-live-server-amd64.iso"
UBUNTU_ISO_URL="https://repo.huaweicloud.com/ubuntu-releases/22.04.5/ubuntu-22.04.5-live-server-amd64.iso"

# ── 输出 ISO ──
OUTPUT_ISO="/home/isobuild/ubuntu-22.04-autoinstall.iso"

# ── 工作目录（解包用，完成后自动清理）──
WORK_DIR="/tmp/iso-inject-work"

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

# ── 退出时清理 ──
cleanup() {
  umount /mnt/ubuntu-iso-ro 2>/dev/null || true
  # 不自动删除 WORK_DIR，方便排查问题
}
trap cleanup EXIT

START_TIME=$(date +%s)

# ══════════════════════════════════════════
log_step "第 1 步：权限 & 依赖检查"
# ══════════════════════════════════════════

# root 检查
[[ $EUID -ne 0 ]] && { log_error "请以 root 权限运行：sudo bash $0"; exit 1; }

# 依赖工具检查
MISSING_DEPS=()
check_dep() {
  local cmd="$1" pkg="${2:-$1}"
  if command -v "$cmd" &>/dev/null; then
    log_ok "  $cmd $(command -v "$cmd")"
  else
    log_warn "  $cmd ← 缺失（将尝试安装 $pkg）"
    MISSING_DEPS+=("$pkg")
  fi
}

log_info "检查必要工具..."
check_dep xorriso    xorriso
check_dep mksquashfs squashfs-tools
check_dep curl       curl
check_dep gpg        gpg
check_dep python3    python3

# 安装缺失依赖
if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  log_info "安装缺失工具：${MISSING_DEPS[*]}"
  apt-get update -q
  apt-get install -y -q "${MISSING_DEPS[@]}"
  log_ok "依赖安装完成。"
else
  log_ok "所有依赖已就绪。"
fi

# xorriso 版本检查（需要 1.4+）
XORRISO_VER=$(xorriso --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
log_info "xorriso 版本：${XORRISO_VER}"

# ── user-data 检查 ──
log_info "检查 user-data 文件：${USER_DATA_FILE}"
if [[ ! -f "${USER_DATA_FILE}" ]]; then
  log_error "user-data 文件不存在：${USER_DATA_FILE}"
  log_error "请将 user-data 文件放在脚本同目录下，或修改脚本顶部 USER_DATA_FILE 变量"
  exit 1
fi

# 验证 YAML 格式
if command -v python3 &>/dev/null; then
  python3 -c "
import sys
try:
    import yaml
    with open('${USER_DATA_FILE}') as f:
        yaml.safe_load(f)
    print('[OK]    user-data YAML 格式正确')
except ImportError:
    print('[WARN]  python3-yaml 未安装，跳过 YAML 校验')
except Exception as e:
    print(f'[ERROR] user-data YAML 格式错误：{e}')
    sys.exit(1)
" || exit 1
fi

# 检查关键字段
if ! grep -q "autoinstall:" "${USER_DATA_FILE}"; then
  log_warn "user-data 中未检测到 'autoinstall:' 字段，请确认格式正确"
fi

log_ok "user-data 检查通过。"

# ── 磁盘空间检查 ──
OUTPUT_DIR="$(dirname "${OUTPUT_ISO}")"
mkdir -p "${OUTPUT_DIR}"
AVAILABLE_GB=$(( $(df -k "${OUTPUT_DIR}" | awk 'NR==2{print $4}') / 1024 / 1024 ))
log_info "输出目录可用空间：${AVAILABLE_GB}GB（至少需要 5GB）"
[[ ${AVAILABLE_GB} -lt 5 ]] && { log_error "磁盘空间不足"; exit 1; }

# ══════════════════════════════════════════
log_step "第 2 步：获取 Ubuntu 22.04 Server ISO"
# ══════════════════════════════════════════

if [[ -f "${UBUNTU_ISO_PATH}" ]]; then
  ISO_SIZE=$(du -sh "${UBUNTU_ISO_PATH}" | cut -f1)
  log_ok "使用本地 ISO：${UBUNTU_ISO_PATH}（${ISO_SIZE}）"
else
  log_info "本地 ISO 不存在，开始下载..."
  log_info "来源：${UBUNTU_ISO_URL}"
  mkdir -p "$(dirname "${UBUNTU_ISO_PATH}")"
  curl -L --progress-bar \
    --retry 3 --retry-delay 5 \
    --connect-timeout 30 \
    "${UBUNTU_ISO_URL}" -o "${UBUNTU_ISO_PATH}" \
  || { log_error "ISO 下载失败，请检查网络或手动下载后重试"; exit 1; }
  log_ok "ISO 下载完成：$(du -sh "${UBUNTU_ISO_PATH}" | cut -f1)"
fi

# ── ISO 完整性粗检（检查文件头魔数）──
ISO_MAGIC=$(file "${UBUNTU_ISO_PATH}" | grep -i "ISO 9660\|DOS/MBR boot sector" || true)
if [[ -z "${ISO_MAGIC}" ]]; then
  log_warn "ISO 文件格式检测异常，可能下载不完整：$(file "${UBUNTU_ISO_PATH}")"
fi

# ══════════════════════════════════════════
log_step "第 3 步：解包 ISO"
# ══════════════════════════════════════════

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p /mnt/ubuntu-iso-ro

log_info "挂载 ISO（只读）..."
mount -o loop,ro "${UBUNTU_ISO_PATH}" /mnt/ubuntu-iso-ro

log_info "复制 ISO 内容（约 1～3 分钟）..."
cp -a /mnt/ubuntu-iso-ro/. "${WORK_DIR}/"
umount /mnt/ubuntu-iso-ro

# 确保所有文件可写
chmod -R u+w "${WORK_DIR}"

log_ok "ISO 解包完成，目录：${WORK_DIR}"
log_info "ISO 内容大小：$(du -sh "${WORK_DIR}" | cut -f1)"

# 确认是 Ubuntu Server（Subiquity）ISO
if [[ ! -f "${WORK_DIR}/casper/vmlinuz" ]]; then
  log_error "未找到 casper/vmlinuz，请确认使用的是 Ubuntu Server Live ISO"
  exit 1
fi
log_ok "确认是 Ubuntu Server（Subiquity）ISO。"

# ══════════════════════════════════════════
log_step "第 4 步：注入 autoinstall 配置"
# ══════════════════════════════════════════

AUTOINSTALL_DIR="${WORK_DIR}/autoinstall"
mkdir -p "${AUTOINSTALL_DIR}"

# 复制 user-data
cp "${USER_DATA_FILE}" "${AUTOINSTALL_DIR}/user-data"

# meta-data 必须存在（可以为空，Subiquity 要求）
touch "${AUTOINSTALL_DIR}/meta-data"

log_ok "autoinstall 配置注入完成："
log_info "  user-data → ${AUTOINSTALL_DIR}/user-data"
log_info "  meta-data → ${AUTOINSTALL_DIR}/meta-data（空文件）"

# ── 显示 user-data 摘要 ──
echo ""
echo -e "  ${BOLD}user-data 关键配置摘要：${RESET}"
python3 - << 'PYEOF'
import sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    ai = data.get('autoinstall', {})
    identity = ai.get('identity', {})
    storage_configs = ai.get('storage', {}).get('config', [])
    disks = [c for c in storage_configs if c.get('type') == 'disk']
    parts = [c for c in storage_configs if c.get('type') == 'partition']
    mounts = [c for c in storage_configs if c.get('type') == 'mount']

    print(f"  主机名：{identity.get('hostname', '未设置')}")
    print(f"  用户名：{identity.get('username', '未设置')}")
    print(f"  语言  ：{ai.get('locale', '未设置')}")
    print(f"  时区  ：{ai.get('user-data', {}).get('timezone', '未设置')}")
    if disks:
        print(f"  目标盘：{disks[0].get('path', '未设置')}")
    print(f"  分区数：{len(parts)} 个")
    for m in mounts:
        print(f"    挂载点 {m.get('path', '?')}")
    ssh = ai.get('ssh', {})
    print(f"  SSH   ：{'启用' if ssh.get('install-server') else '禁用'}")
except Exception as e:
    print(f"  （摘要解析失败：{e}）")
PYEOF
python3 - "${AUTOINSTALL_DIR}/user-data" << 'PYEOF' || true
import sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    ai = data.get('autoinstall', {})
    identity = ai.get('identity', {})
    storage_configs = ai.get('storage', {}).get('config', [])
    disks = [c for c in storage_configs if c.get('type') == 'disk']
    parts = [c for c in storage_configs if c.get('type') == 'partition']
    mounts = [c for c in storage_configs if c.get('type') == 'mount']

    print(f"  主机名：{identity.get('hostname', '未设置')}")
    print(f"  用户名：{identity.get('username', '未设置')}")
    print(f"  语言  ：{ai.get('locale', '未设置')}")
    print(f"  时区  ：{ai.get('user-data', {}).get('timezone', '未设置')}")
    if disks:
        print(f"  目标盘：{disks[0].get('path', '未设置')}")
    print(f"  分区数：{len(parts)} 个")
    for m in mounts:
        print(f"    挂载点 {m.get('path', '?')}")
    ssh = ai.get('ssh', {})
    print(f"  SSH   ：{'启用' if ssh.get('install-server') else '禁用'}")
except Exception as e:
    print(f"  （摘要解析失败：{e}）")
PYEOF
echo ""

# ══════════════════════════════════════════
log_step "第 5 步：修改 GRUB 引导，启用 autoinstall"
# ══════════════════════════════════════════

GRUB_CFG="${WORK_DIR}/boot/grub/grub.cfg"

# 备份原始 grub.cfg
cp "${GRUB_CFG}" "${GRUB_CFG}.orig"

# 在内核参数中加入 autoinstall 数据源
# ds=nocloud;s=/cdrom/autoinstall/  告诉 cloud-init 从 ISO 的 autoinstall/ 目录读取配置
# 注意：分号在 GRUB 里需要转义为 \;
sed -i 's|linux\(.*\)quiet splash\(.*\)---|linux\1quiet splash autoinstall ds=nocloud\\;s=/cdrom/autoinstall/ \2---|g' \
  "${GRUB_CFG}" 2>/dev/null || true

# 如果上面的 sed 没匹配到（不同版本 ISO 格式不同），直接重写 grub.cfg
if ! grep -q "autoinstall" "${GRUB_CFG}"; then
  log_warn "原始 grub.cfg 格式不匹配，重写引导配置..."
  cat > "${GRUB_CFG}" << 'GRUBEOF'
set default=0
set timeout=5

if loadfont /boot/grub/font.pf2 ; then
  set gfxmode=auto
  insmod efi_gop
  insmod efi_uga
  insmod gfxterm
  terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Ubuntu 22.04 自动安装（autoinstall）" {
    set gfxpayload=keep
    linux   /casper/vmlinuz quiet splash autoinstall ds=nocloud\;s=/cdrom/autoinstall/ ---
    initrd  /casper/initrd
}

menuentry "Ubuntu 22.04 自动安装（无图形，Safe Graphics）" {
    set gfxpayload=keep
    linux   /casper/vmlinuz quiet splash nomodeset autoinstall ds=nocloud\;s=/cdrom/autoinstall/ ---
    initrd  /casper/initrd
}

menuentry "Ubuntu 22.04 交互式安装（跳过 autoinstall）" {
    set gfxpayload=keep
    linux   /casper/vmlinuz quiet splash ---
    initrd  /casper/initrd
}
GRUBEOF
fi

# 同步更新 isolinux（BIOS 引导兼容）
ISOLINUX_CFG="${WORK_DIR}/isolinux/txt.cfg"
if [[ -f "${ISOLINUX_CFG}" ]]; then
  cat > "${ISOLINUX_CFG}" << 'ISOLINUXEOF'
default autoinstall
label autoinstall
  menu label Ubuntu 22.04 Auto Install
  kernel /casper/vmlinuz
  append initrd=/casper/initrd quiet splash autoinstall ds=nocloud;s=/cdrom/autoinstall/ ---
ISOLINUXEOF
fi

log_ok "GRUB 引导配置修改完成。"

# ══════════════════════════════════════════
log_step "第 6 步：重新封装 ISO"
# ══════════════════════════════════════════

rm -f "${OUTPUT_ISO}"

# 检查 hybrid 引导文件（用于 UEFI + BIOS 双模式）
MBR_IMG="${WORK_DIR}/boot/grub/i386-pc/boot_hybrid.img"
EFI_IMG="${WORK_DIR}/boot/grub/efi.img"

log_info "封装 ISO 中..."

if [[ -f "${MBR_IMG}" && -f "${EFI_IMG}" ]]; then
  log_info "使用 UEFI + Legacy BIOS 双模式引导"
  xorriso -as mkisofs \
    -r \
    -V "Ubuntu 22.04 AutoInstall" \
    -o "${OUTPUT_ISO}" \
    --grub2-mbr "${MBR_IMG}" \
    -partition_offset 16 \
    --mbr-force-bootable \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${EFI_IMG}" \
    -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot/grub/boot.cat' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
    -no-emul-boot \
    "${WORK_DIR}" 2>&1 | grep -v "^$" | tail -10
else
  log_warn "未找到 hybrid 引导文件，使用 GRUB EFI 单模式"
  xorriso -as mkisofs \
    -r \
    -V "Ubuntu 22.04 AutoInstall" \
    -o "${OUTPUT_ISO}" \
    -c '/boot/grub/boot.cat' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "${WORK_DIR}" 2>&1 | grep -v "^$" | tail -10
fi

log_ok "ISO 封装完成。"

# ── 清理工作目录 ──
log_info "清理工作目录..."
rm -rf "${WORK_DIR}"

# ══════════════════════════════════════════
# 完成报告
# ══════════════════════════════════════════

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ISO_SIZE=$(du -sh "${OUTPUT_ISO}" | cut -f1)

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              ✅  ISO 构建成功！                      ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${BOLD}总耗时 ：${RESET}$(( ELAPSED/60 )) 分 $(( ELAPSED%60 )) 秒"
echo -e "  ${BOLD}输出文件：${RESET}${OUTPUT_ISO}（${ISO_SIZE}）"
echo ""
echo -e "  ${BOLD}使用方式：${RESET}"
echo    "    • 刻录到 U 盘：sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo    "    • 虚拟机测试 ：直接挂载 ISO 启动"
echo    "    • PXE 网络启动：将 ISO 放到 PXE 服务器"
echo ""
echo -e "  ${RED}${BOLD}⚠  警告：ISO 启动后将自动安装，目标磁盘 /dev/sda 数据将被清空！${RESET}"
echo ""
