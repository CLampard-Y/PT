#!/usr/bin/env bash
# ===========================================================
#  PT 保种服务器 — 引导脚本 (在全新VPS上第一个运行的脚本)
#
#  功能: Git Sparse Checkout 拉取代码 + 环境初始化
#
#  使用方法 (全新 Debian 12 VPS 上执行):
#    方式一: 公开仓库
#      bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/PT/main/common_scripts/bootstrap.sh)
#
#    方式二: 手动下载后执行
#      curl -O https://raw.githubusercontent.com/你的用户名/PT/main/common_scripts/bootstrap.sh
#      bash bootstrap.sh
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

# ===================== 交互式配置 =====================
DEPLOY_DIR="/home/BT"
NODE_NAME="PT_JP"
REPO_BRANCH="main"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       PT 保种服务器 — 引导部署                   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# 获取仓库地址
if [[ -n "${PT_REPO_URL:-}" ]]; then
    REPO_URL="${PT_REPO_URL}"
    info "使用环境变量中的仓库地址"
else
    echo "请输入 GitHub 仓库地址:"
    echo "  HTTPS 格式: https://github.com/用户名/PT.git"
    echo "  SSH 格式:   git@github.com:用户名/PT.git"
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
read -rp "确认开始部署？(y/N): " CONFIRM
[[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]] && { echo "已取消"; exit 0; }

# =============================================================
#  Step 1: 安装 Git
# =============================================================
phase "Step 1/4: 安装 Git"

apt-get update -qq
apt-get install -y -qq git curl wget > /dev/null 2>&1
info "Git 已安装: $(git --version)"

# 验证 Git 版本 >= 2.25
GIT_MAJOR=$(git --version | grep -oP '\d+' | head -1)
GIT_MINOR=$(git --version | grep -oP '\d+' | sed -n '2p')
if [[ ${GIT_MAJOR} -lt 2 ]] || [[ ${GIT_MAJOR} -eq 2 && ${GIT_MINOR} -lt 25 ]]; then
    error "Git 版本过低，Sparse Checkout 需要 >= 2.25"
fi
info "Git 版本满足 Sparse Checkout 要求 ✓"

# =============================================================
#  Step 2: Git Sparse Checkout
# =============================================================
phase "Step 2/4: Git Sparse Checkout 稀疏检出"

# 备份旧 .env (如果存在)
[[ -f "${DEPLOY_DIR}/${NODE_NAME}/.env" ]] && \
    cp "${DEPLOY_DIR}/${NODE_NAME}/.env" "/tmp/pt_env_backup_$(date +%s)" && \
    warn "已备份旧 .env 到 /tmp/"

# 清理并重新初始化
rm -rf "${DEPLOY_DIR}"
mkdir -p "${DEPLOY_DIR}"
cd "${DEPLOY_DIR}"

git init
info "Git 仓库已初始化"

git remote add origin "${REPO_URL}"
info "远程仓库已添加"

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
#  Step 3: 运行环境初始化
# =============================================================
phase "Step 3/4: 环境初始化 (Docker, BBR, 内核优化)"

INIT_SCRIPT="${DEPLOY_DIR}/common_scripts/init_env.sh"
if [[ -f "${INIT_SCRIPT}" ]]; then
    chmod +x "${INIT_SCRIPT}"
    bash "${INIT_SCRIPT}"
    info "环境初始化完成"
else
    error "找不到 ${INIT_SCRIPT}"
fi

# =============================================================
#  Step 4: 提示下一步
# =============================================================
phase "Step 4/4: 准备重启"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ 引导阶段完成！                                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  ⚠️  现在需要重启 VPS 使内核参数完全生效:               ║"
echo "║                                                          ║"
echo "║     sudo reboot                                          ║"
echo "║                                                          ║"
echo "║  重启后 SSH 重新登录，执行以下命令完成部署:              ║"
echo "║                                                          ║"
echo "║     cd /home/BT/PT_JP                                    ║"
echo "║     sudo bash scripts/deploy.sh                          ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

read -rp "是否现在重启？(Y/n): " DO_REBOOT
if [[ "${DO_REBOOT}" != "n" && "${DO_REBOOT}" != "N" ]]; then
    info "3秒后重启..."
    sleep 3
    reboot
else
    warn "请手动执行: sudo reboot"
fi