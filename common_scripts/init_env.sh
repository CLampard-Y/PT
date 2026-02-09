#!/usr/bin/env bash
# ===========================================================
#  PT 保种服务器 — 业务环境预检与初始化
#
#  职责 (仅 PT 业务层，不涉及系统底层):
#    1. Pre-flight Check: 验证 Docker/Compose/jq 已安装
#    2. Permission Logic: 检测 PUID/PGID 并导出
#    3. Directory Structure: 确保业务目录结构完整
#    4. 生成 .env 基础变量 (供 deploy.sh 使用)
#
#  前置依赖: Server-Ops 已完成系统初始化
#  调用方式: source common_scripts/init_env.sh
#           或 bash common_scripts/init_env.sh
# ===========================================================
set -euo pipefail

# ── 防止重复 source ──
[[ -n "${_INIT_ENV_LOADED:-}" ]] && return 0 2>/dev/null || true
_INIT_ENV_LOADED=1

# ── 颜色/日志 (仅在未定义时声明，避免覆盖调用者的同名函数) ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if ! declare -F info &>/dev/null; then
    info()  { echo -e "${GREEN}[✓]${NC} $*"; }
fi
if ! declare -F warn &>/dev/null; then
    warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fi
if ! declare -F error &>/dev/null; then
    error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
fi
step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ── 路径常量 ──
BT_HOME="/home/BT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   PT 保种服务器 — 业务环境预检                   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# =============================================================
#  Step 1: Pre-flight Check (前置依赖验证)
# =============================================================
step "Step 1/3: 前置依赖验证"

# Docker
if ! command -v docker &>/dev/null; then
    error "Docker 未安装！请先运行 Server-Ops 初始化:\n  git clone <REPO> /home/Server-Ops && sudo bash /home/Server-Ops/setup.sh"
fi
info "Docker: $(docker --version | grep -oP '\d+\.\d+\.\d+')"

# Docker Compose
if ! docker compose version &>/dev/null; then
    error "Docker Compose 插件未安装！请先运行 Server-Ops 初始化"
fi
info "Compose: $(docker compose version --short)"

# jq (用于安全编辑 JSON 配置)
if ! command -v jq &>/dev/null; then
    warn "jq 未安装，尝试自动安装..."
    apt-get install -y -qq jq > /dev/null 2>&1 || warn "jq 安装失败，部分功能将降级"
fi
command -v jq &>/dev/null && info "jq: $(jq --version)"

# curl (健康检查需要)
command -v curl &>/dev/null && info "curl: 已就绪" || warn "curl 未安装，健康检查将跳过"

# /home/BT 可写性
if [[ ! -d "${BT_HOME}" ]]; then
    mkdir -p "${BT_HOME}"
    info "已创建 ${BT_HOME}"
fi

if [[ ! -w "${BT_HOME}" ]]; then
    error "${BT_HOME} 不可写！请检查权限: ls -la /home/BT"
fi
info "${BT_HOME} 可写 ✓"

# =============================================================
#  Step 2: Permission Logic (PUID/PGID 检测)
# =============================================================
step "Step 2/3: 权限检测 (PUID/PGID)"

# 获取实际执行用户 (即使通过 sudo 也能获取原始用户)
if [[ -n "${SUDO_USER:-}" ]]; then
    DETECTED_PUID=$(id -u "${SUDO_USER}")
    DETECTED_PGID=$(id -g "${SUDO_USER}")
    DETECTED_USER="${SUDO_USER}"
else
    DETECTED_PUID=$(id -u)
    DETECTED_PGID=$(id -g)
    DETECTED_USER=$(whoami)
fi

# 如果是 root 直接执行 (非 sudo)，使用 1000:1000 避免容器以 root 运行
if [[ "${DETECTED_PUID}" -eq 0 && -z "${SUDO_USER:-}" ]]; then
    DETECTED_PUID=1000
    DETECTED_PGID=1000
    DETECTED_USER="uid:1000"
    warn "以 root 直接执行，容器将使用 PUID=1000 PGID=1000"
fi

export PUID="${DETECTED_PUID}"
export PGID="${DETECTED_PGID}"
export TZ="Asia/Shanghai"

info "PUID=${PUID} (${DETECTED_USER})"
info "PGID=${PGID}"
info "TZ=${TZ}"

# =============================================================
#  Step 3: Directory Structure (业务目录创建)
# =============================================================
step "Step 3/3: 业务目录结构"

# 定义所有节点通用的子目录结构
create_node_dirs() {
    local node_dir="$1"
    local dirs=(
        "config/transmission"
        "config/flexget"
        "data/complete"
        "data/incomplete"
        "watch"
        "scripts"
        "logs"
    )

    for d in "${dirs[@]}"; do
        mkdir -p "${node_dir}/${d}"
    done

    # 修正权限: 确保容器用户可读写
    chown -R "${PUID}:${PGID}" "${node_dir}/config" 2>/dev/null || true
    chown -R "${PUID}:${PGID}" "${node_dir}/data" 2>/dev/null || true
    chown -R "${PUID}:${PGID}" "${node_dir}/watch" 2>/dev/null || true

    info "目录结构已就绪: ${node_dir}/"
}

# 自动检测当前仓库中的节点目录
for node in "${BT_HOME}"/PT_*/; do
    [[ -d "${node}" ]] || continue
    create_node_dirs "${node}"
done

# 如果没有找到任何节点目录，至少确保 BT_HOME 存在
if ! ls -d "${BT_HOME}"/PT_*/ &>/dev/null; then
    warn "未检测到节点目录 (PT_*)，仅确保 ${BT_HOME} 存在"
fi

# ── 完成报告 ──
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}  ✅ PT 业务环境预检完成"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
printf "${GREEN}║${NC}  %-12s %-36s\n" "PUID:" "${PUID}"
printf "${GREEN}║${NC}  %-12s %-36s\n" "PGID:" "${PGID}"
printf "${GREEN}║${NC}  %-12s %-36s\n" "TZ:" "${TZ}"
printf "${GREEN}║${NC}  %-12s %-36s\n" "BT_HOME:" "${BT_HOME}"
printf "${GREEN}║${NC}  %-12s %-36s\n" "Docker:" "$(docker --version | grep -oP '\d+\.\d+\.\d+')"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""