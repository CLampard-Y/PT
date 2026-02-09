#!/usr/bin/env bash
# ===========================================================
#  PT 保种服务器 — 引导脚本 (瘦身版)
#
#  职责: 仅负责 Git Sparse Checkout 拉取 PT 业务代码
#  前置: 已通过 Server-Ops 完成系统初始化 (Docker/BBR/SSH等)
#
#  使用方法:
#    bash <(curl -fsSL https://raw.githubusercontent.com/<用户名>/PT/main/common_scripts/bootstrap.sh)
# ===========================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
phase() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
          echo -e "${CYAN}  $1${NC}"
          echo -e "${CYAN}══════════════════════════════════════════${NC}\n"; }

# ===================== 前置检查 =====================
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# 检查 Server-Ops 是否已完成系统初始化
if ! command -v docker &>/dev/null; then
    error "Docker 未安装！请先运行 Server-Ops 初始化:\n  git clone <REPO> /home/Server-Ops && sudo bash /home/Server-Ops/setup.sh"
fi
if ! command -v git &>/dev/null; then
    error "Git 未安装！请先运行 Server-Ops 初始化"
fi
info "前置检查通过: Docker $(docker --version | grep -oP '\d+\.\d+\.\d+'), Git $(git --version | grep -oP '\d+\.\d+\.\d+')"

# ===================== 交互式配置 =====================
DEPLOY_DIR="/home/BT"
NODE_NAME="PT_JP"
REPO_BRANCH="main"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       PT 保种服务器 — 代码拉取                   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# 获取仓库地址
if [[ -n "${PT_REPO_URL:-}" ]]; then
    REPO_URL="${PT_REPO_URL}"
    info "使用环境变量中的仓库地址"
else
    echo "请输入 PT 仓库地址:"
    echo "  HTTPS: https://github.com/用户名/PT.git"
    echo "  SSH:   git@github.com:用户名/PT.git"
    echo ""
    read -rp "仓库地址: " REPO_URL
    [[ -z "${REPO_URL}" ]] && error "仓库地址不能为空"
fi

echo ""
info "仓库:  ${REPO_URL}"
info "分支:  ${REPO_BRANCH}"
info "节点:  ${NODE_NAME}"
info "目录:  ${DEPLOY_DIR}"
echo ""
read -rp "确认开始？(y/N): " CONFIRM
[[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]] && { echo "已取消"; exit 0; }

# =============================================================
#  Step 1: Git Sparse Checkout
# =============================================================
phase "Step 1/2: Git Sparse Checkout 稀疏检出"

# 验证 Git 版本 >= 2.25
GIT_MAJOR=$(git --version | grep -oP '\d+' | head -1)
GIT_MINOR=$(git --version | grep -oP '\d+' | sed -n '2p')
if [[ ${GIT_MAJOR} -lt 2 ]] || [[ ${GIT_MAJOR} -eq 2 && ${GIT_MINOR} -lt 25 ]]; then
    error "Git 版本过低，Sparse Checkout 需要 >= 2.25"
fi

# 备份旧 .env (如果存在) — 备份到 /home/BT 内部
ENV_BACKUP_DIR="${DEPLOY_DIR}/.backups"
if [[ -f "${DEPLOY_DIR}/${NODE_NAME}/.env" ]]; then
    mkdir -p "${ENV_BACKUP_DIR}"
    cp "${DEPLOY_DIR}/${NODE_NAME}/.env" "${ENV_BACKUP_DIR}/env_backup_$(date +%s)"
    warn "已备份旧 .env 到 ${ENV_BACKUP_DIR}/"
fi

# 清理并重新初始化
rm -rf "${DEPLOY_DIR}"
mkdir -p "${DEPLOY_DIR}"
cd "${DEPLOY_DIR}"

git init
git remote add origin "${REPO_URL}"
git sparse-checkout init --cone
git sparse-checkout set common_scripts "${NODE_NAME}"
info "Sparse Checkout 规则: common_scripts + ${NODE_NAME}"

git pull origin "${REPO_BRANCH}"
info "代码拉取完成"

# 验证
echo "  拉取到的目录:"
for d in common_scripts "${NODE_NAME}"; do
    if [[ -d "${DEPLOY_DIR}/${d}" ]]; then
        echo -e "    ${GREEN}✓${NC} ${d}/"
    else
        echo -e "    ${RED}✗${NC} ${d}/ (缺失!)"
    fi
done

# =============================================================
#  Step 2: 提示下一步
# =============================================================
phase "Step 2/2: 完成"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ PT 代码拉取完成！                                    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  执行以下命令开始部署 PT 业务:                           ║"
echo "║                                                          ║"
echo "║     cd /home/BT/PT_JP                                    ║"
echo "║     sudo bash scripts/deploy.sh                          ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
