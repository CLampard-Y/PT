#!/usr/bin/env bash
# ===========================================================
#  PT 保种服务器 — 通用环境初始化脚本
#  适用系统: Debian 12 / Ubuntu 22.04+
#  执行方式: sudo bash common_scripts/init_env.sh
#
#  功能清单:
#    1. 系统更新 + 基础工具
#    2. 时区设置 (Asia/Shanghai)
#    3. 内核参数优化 (sysctl + BBR)
#    4. 文件描述符 (ulimit)
#    5. Docker + Docker Compose
#    6. Swap 保险
# ===========================================================
set -euo pipefail

# ===================== 辅助函数 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓ DONE]${NC} $*"; }
warn()  { echo -e "${YELLOW}[! WARN]${NC} $*"; }
error() { echo -e "${RED}[✗ FAIL]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
          echo -e "${CYAN}  STEP $1: $2${NC}"
          echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ===================== 前置检查 =====================
[[ $EUID -ne 0 ]] && error "请使用 root 权限运行: sudo bash $0"

# 定位脚本所在目录（用于找到 sysctl_optim.conf）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   PT 保种服务器 — 环境初始化             ║"
echo "║   脚本路径: ${SCRIPT_DIR}"
echo "╚══════════════════════════════════════════╝"
echo ""

# ==================== STEP 1 ====================
step "1/6" "系统更新与基础工具安装"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" \
                       -o Dpkg::Options::="--force-confold"

PACKAGES=(
    curl wget git vim unzip htop
    ca-certificates gnupg lsb-release
    net-tools iotop sysstat jq
    tree ncdu
)

apt-get install -y -qq "${PACKAGES[@]}" > /dev/null 2>&1
info "已安装: ${PACKAGES[*]}"

# ==================== STEP 2 ====================
step "2/6" "设置时区 Asia/Shanghai"

timedatectl set-timezone Asia/Shanghai
info "当前时区: $(timedatectl show --property=Timezone --value)"
info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ==================== STEP 3 ====================
step "3/6" "应用内核参数优化 (sysctl + BBR)"

SYSCTL_SRC="${SCRIPT_DIR}/sysctl_optim.conf"
SYSCTL_DST="/etc/sysctl.d/99-pt-optim.conf"

if [[ -f "${SYSCTL_SRC}" ]]; then
    cp -v "${SYSCTL_SRC}" "${SYSCTL_DST}"
    sysctl --system > /dev/null 2>&1
    info "内核参数已从 ${SYSCTL_SRC} 加载"
else
    error "找不到 ${SYSCTL_SRC}，请确认仓库结构完整"
fi

# 验证 BBR
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "${BBR_STATUS}" == "bbr" ]]; then
    info "BBR 拥塞控制: 已生效 ✓"
else
    warn "BBR 当前值: ${BBR_STATUS}（可能需要重启生效，内核需 >= 4.9）"
fi

# 验证 file-max
FILEMAX=$(sysctl -n fs.file-max 2>/dev/null)
info "fs.file-max = ${FILEMAX}"

# ==================== STEP 4 ====================
step "4/6" "配置文件描述符限制 (ulimit)"

cat > /etc/security/limits.d/99-pt-nofile.conf << 'LIMITS_EOF'
# PT保种服务器 — 5000+种子需要大量文件描述符
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
LIMITS_EOF

# 确保 PAM 加载 limits 模块
if [[ -f /etc/pam.d/common-session ]]; then
    grep -q "pam_limits.so" /etc/pam.d/common-session || \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

# systemd 全局文件描述符限制
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-pt-limits.conf << 'SYSD_EOF'
[Manager]
DefaultLimitNOFILE=1048576
SYSD_EOF

systemctl daemon-reload
info "ulimit nofile 已设为 1048576（重新登录后对 shell 生效）"

# ==================== STEP 5 ====================
step "5/6" "安装 Docker & Docker Compose"

if command -v docker &> /dev/null; then
    info "Docker 已存在，跳过安装: $(docker --version)"
else
    # 添加 Docker 官方 GPG key
    install -m 0755 -d /etc/apt/keyrings
    DISTRO_ID=$(. /etc/os-release && echo "$ID")
    curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # 添加 Docker 仓库
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    cat > /etc/apt/sources.list.d/docker.list << DOCKER_EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${CODENAME} stable
DOCKER_EOF

    apt-get update -qq
    apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        > /dev/null 2>&1

    systemctl enable --now docker
    info "Docker 安装完成: $(docker --version)"
fi

# 验证 Docker Compose
if docker compose version &> /dev/null; then
    info "Docker Compose: $(docker compose version --short)"
else
    error "Docker Compose 插件安装失败，请检查"
fi

# ==================== STEP 6 ====================
step "6/6" "创建 Swap 保险 (防 OOM)"

SWAP_SIZE="2G"
if [[ $(swapon --show | wc -l) -gt 0 ]]; then
    info "Swap 已存在: $(free -h | awk '/Swap/{print $2}')，跳过"
else
    warn "未检测到 Swap，正在创建 ${SWAP_SIZE}..."
    fallocate -l ${SWAP_SIZE} /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile

    # 写入 fstab 持久化
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    info "Swap ${SWAP_SIZE} 已创建并启用"
fi

# ==================== 完成报告 ====================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║            ✅  环境初始化完成！                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
printf "║  %-12s %-36s║\n" "BBR:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "║  %-12s %-36s║\n" "Docker:" "$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')"
printf "║  %-12s %-36s║\n" "Compose:" "$(docker compose version --short 2>/dev/null)"
printf "║  %-12s %-36s║\n" "时区:" "$(timedatectl show --property=Timezone --value)"
printf "║  %-12s %-36s║\n" "Swap:" "$(free -h | awk '/Swap/{print $2}')"
printf "║  %-12s %-36s║\n" "file-max:" "$(sysctl -n fs.file-max)"
echo "║                                                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  ⚠️  建议执行一次重启使所有参数完全生效:         ║"
echo "║     sudo reboot                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""