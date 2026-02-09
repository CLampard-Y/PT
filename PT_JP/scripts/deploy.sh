#!/usr/bin/env bash
# ===========================================================
#  PT_JP 日本节点 — 容器部署与配置脚本
#
#  前置条件: 已运行 bootstrap.sh 完成环境初始化并重启
#  执行方式: cd /home/BT/PT_JP && sudo bash scripts/deploy.sh
#
#  本脚本负责:
#    阶段 D: 启动 Transmission + FlexGet 容器
#    阶段 E: 安装 Transmission Web Control + 覆盖配置
#    阶段 F: 配置 FlexGet RSS 变量
#    阶段 G: 注册监控任务
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
phase() { echo -e "\n${CYAN}╔══════════════════════════════════════════════╗${NC}"
          echo -e "${CYAN}║  阶段 $1: $2${NC}"
          echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}\n"; }

# ===================== 前置检查 =====================
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行: sudo bash $0"

# ===================== 配置变量 =====================
DEPLOY_DIR="/home/BT"
NODE_NAME="PT_JP"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       PT_JP 日本节点 — 容器部署                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  目录:   ${DEPLOY_DIR}/${NODE_NAME}"
echo "║  客户端: Transmission 4.0.6 + FlexGet RSS"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ===================== 前置环境检查 =====================
# 确认 bootstrap.sh 已经运行过
if ! command -v docker &>/dev/null; then
    error "Docker 未安装！请先运行 bootstrap.sh:\n  sudo bash /home/BT/common_scripts/bootstrap.sh"
fi

if [[ ! -d "${DEPLOY_DIR}/${NODE_NAME}" ]]; then
    error "${DEPLOY_DIR}/${NODE_NAME} 不存在！请先运行 bootstrap.sh"
fi

info "前置检查通过: Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"

# 清理旧的 qBittorrent 容器 (如果存在)
if docker ps -a --format '{{.Names}}' | grep -q 'qbittorrent_jp'; then
    warn "检测到旧的 qBittorrent 容器，正在清理..."
    docker rm -f qbittorrent_jp 2>/dev/null || true
    info "旧容器已清理"
fi

# =============================================================
#  阶段 D: 启动 Transmission + FlexGet 容器
# =============================================================
phase "D" "启动 Transmission + FlexGet 容器"

cd "${DEPLOY_DIR}/${NODE_NAME}"

# 创建目录结构
mkdir -p ./data/complete ./data/incomplete ./watch
mkdir -p ./config/transmission ./config/flexget
info "目录结构已创建"

# 创建 .env 文件
if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        cp .env.example .env
        warn ".env 已从模板创建，请务必编辑!"
        warn "必须修改: TR_PASS, MT_RSS_URL (passkey)"
        echo ""
        read -rp "是否现在编辑 .env？(Y/n): " EDIT_ENV
        if [[ "${EDIT_ENV}" != "n" && "${EDIT_ENV}" != "N" ]]; then
            vim .env || nano .env || vi .env
        fi
    else
        error "找不到 .env.example 模板文件"
    fi
else
    info ".env 文件已存在，跳过创建"
fi

# 备份仓库预置的 settings.json (容器首次启动会覆盖)
TR_CONF_REPO="./config/transmission/settings.json"
TR_CONF_BACKUP="/tmp/settings.json.repo_preset"
if [[ -f "${TR_CONF_REPO}" ]]; then
    cp "${TR_CONF_REPO}" "${TR_CONF_BACKUP}"
    info "已备份仓库预置 settings.json"
fi

# 启动 Transmission (先不启动 FlexGet，等配置完成)
info "启动 Transmission 容器..."
docker compose up -d transmission

info "等待 Transmission 初始化 (15秒)..."
sleep 15

# 读取 .env 中的认证信息用于显示
TR_USER_DISPLAY=$(grep -oP '^TR_USER=\K.*' .env 2>/dev/null || echo 'admin')
VPS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo '你的IP')

echo ""
echo "  ┌──────────────────────────────────────────┐"
echo "  │  📋 Transmission 登录信息                │"
echo "  ├──────────────────────────────────────────┤"
printf "  │  地址: http://%-27s│\n" "${VPS_IP}:9091"
printf "  │  用户: %-33s│\n" "${TR_USER_DISPLAY}"
echo "  │  密码: (你在 .env 中设置的 TR_PASS)      │"
echo "  └──────────────────────────────────────────┘"
echo ""

# 验证容器状态
if docker ps --format '{{.Names}}' | grep -q 'transmission_jp'; then
    info "Transmission 容器运行正常 ✓"
else
    error "Transmission 启动失败，请检查: docker logs transmission_jp"
fi

# =============================================================
#  阶段 E: 安装 TWC + 覆盖 Transmission 配置
# =============================================================
phase "E" "安装 Transmission Web Control + 覆盖配置"

# ---- 安装 Transmission Web Control (第三方WebUI) ----
TWC_DIR="./config/transmission/transmission-web-control"
if [[ ! -d "${TWC_DIR}/src" ]]; then
    info "安装 Transmission Web Control..."
    mkdir -p "${TWC_DIR}"
    TWC_REPO="https://github.com/transmission-web-control/transmission-web-control"
    TWC_VER="v1.6.1-update2"
    if wget -qO /tmp/twc.tar.gz \
        "${TWC_REPO}/archive/refs/tags/${TWC_VER}.tar.gz" 2>/dev/null; then
        tar -xzf /tmp/twc.tar.gz -C /tmp/
        cp -r /tmp/transmission-web-control-*/src "${TWC_DIR}/"
        rm -rf /tmp/twc.tar.gz /tmp/transmission-web-control-*
        info "TWC 安装完成 ✓"
    else
        warn "TWC 下载失败，将使用原版 WebUI"
    fi
else
    info "TWC 已存在，跳过安装"
fi

# ---- 覆盖 settings.json ----
TR_CONF="./config/transmission/settings.json"

if [[ -f "${TR_CONF_BACKUP}" ]]; then
    info "用仓库预置配置覆盖默认 settings.json..."

    docker compose stop transmission
    sleep 3

    cp "${TR_CONF_BACKUP}" "${TR_CONF}"
    rm -f "${TR_CONF_BACKUP}"

    # 将 .env 中的密码写入 settings.json (使用 jq，防止特殊字符破坏JSON)
    TR_PASS_VAL=$(grep -oP '^TR_PASS=\K.*' .env 2>/dev/null || echo 'changeme')
    TR_USER_VAL=$(grep -oP '^TR_USER=\K.*' .env 2>/dev/null || echo 'admin')
    if command -v jq &>/dev/null; then
        jq --arg user "${TR_USER_VAL}" --arg pass "${TR_PASS_VAL}" \
            '."rpc-username" = $user | ."rpc-password" = $pass' \
            "${TR_CONF}" > "${TR_CONF}.tmp" && mv "${TR_CONF}.tmp" "${TR_CONF}"
        info "RPC 认证已通过 jq 写入 settings.json"
    else
        warn "jq 未安装，尝试 python3 回退..."
        python3 - "${TR_USER_VAL}" "${TR_PASS_VAL}" << 'PYEOF' 2>/dev/null && \
            info "RPC 认证已通过 python3 写入" || \
            warn "自动写入失败，请手动编辑 ${TR_CONF}"
import json, sys, glob
conf = glob.glob('./config/transmission/settings.json')[0]
with open(conf, 'r') as f:
    cfg = json.load(f)
cfg['rpc-username'] = sys.argv[1]
cfg['rpc-password'] = sys.argv[2]
with open(conf, 'w') as f:
    json.dump(cfg, f, indent=4)
PYEOF
    fi

    docker compose up -d transmission
    sleep 10

    # 验证关键参数
    grep -q '"cache-size-mb": 1024' "${TR_CONF}" 2>/dev/null && info "磁盘缓存 1024MB ✓"
    grep -q '"peer-limit-global": 1600' "${TR_CONF}" 2>/dev/null && info "全局连接数 1600 ✓"
    grep -q '"seed-queue-enabled": false' "${TR_CONF}" 2>/dev/null && info "做种无限制 ✓"
    grep -q '"preallocation": 2' "${TR_CONF}" 2>/dev/null && info "完全预分配 (Mode 2) ✓"

    info "Transmission 配置覆盖完成 ✓"
else
    warn "未找到预置配置备份，使用容器默认配置"
fi

# =============================================================
#  阶段 F: 配置 FlexGet RSS 变量 + 启动
# =============================================================
phase "F" "配置 FlexGet RSS"

# 从 .env 读取变量写入 FlexGet variables.yml
FG_VARS="./config/flexget/variables.yml"
MT_RSS=$(grep -oP '^MT_RSS_URL=\K.*' .env 2>/dev/null || echo '')
TR_USER_FG=$(grep -oP '^TR_USER=\K.*' .env 2>/dev/null || echo 'admin')
TR_PASS_FG=$(grep -oP '^TR_PASS=\K.*' .env 2>/dev/null || echo 'changeme')

if [[ -n "${MT_RSS}" && "${MT_RSS}" != *"YOUR_PASSKEY_HERE"* ]]; then
    cat > "${FG_VARS}" << FGEOF
tr_user: ${TR_USER_FG}
tr_pass: ${TR_PASS_FG}
mt_rss_url: ${MT_RSS}
FGEOF
    info "FlexGet variables.yml 已生成"
else
    warn "MT_RSS_URL 未配置或仍为默认值!"
    warn "请编辑 .env 填入真实 passkey，然后重新运行此脚本"
    warn "或手动编辑: vim ${FG_VARS}"
fi

# 启动 FlexGet
info "启动 FlexGet 容器..."
docker compose up -d flexget
sleep 10

if docker ps --format '{{.Names}}' | grep -q 'flexget_jp'; then
    info "FlexGet 容器运行正常 ✓"
    # 测试执行一次
    info "测试 FlexGet RSS 抓取 (dry-run)..."
    docker exec flexget_jp sh -c 'flexget --test execute --tasks mt_free_seed 2>&1 | tail -10' || \
        warn "dry-run 执行失败（首次运行可能需要等待数据库初始化）"
else
    warn "FlexGet 启动失败，请检查: docker logs flexget_jp"
fi

echo ""
echo "  FlexGet 自动化说明:"
echo "  - 每15分钟自动抓取 MT Free 种子 (< 100MB)"
echo "  - 自动推送到 Transmission 下载"
echo "  - 无需手动配置 RSS 规则 ✓"
echo ""

# =============================================================
#  阶段 G: 注册监控任务 + 最终验证
# =============================================================
phase "G" "注册监控任务 & 最终验证"

# 注册 crontab
SETUP_CRON="${DEPLOY_DIR}/${NODE_NAME}/scripts/setup_cron.sh"
if [[ -f "${SETUP_CRON}" ]]; then
    chmod +x "${SETUP_CRON}"
    bash "${SETUP_CRON}"
    info "磁盘守护定时任务已注册"
else
    warn "未找到 ${SETUP_CRON}，请手动注册 crontab"
fi

# 手动执行一次磁盘检查
DISK_GUARD="${DEPLOY_DIR}/${NODE_NAME}/scripts/disk_guard.sh"
if [[ -f "${DISK_GUARD}" ]]; then
    chmod +x "${DISK_GUARD}"
    bash "${DISK_GUARD}" || true
    info "磁盘守护脚本首次执行完成"
fi

# ==================== 部署完成报告 ====================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          🎉  PT_JP 日本节点部署完成！               ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      ║"
printf "║  %-14s %-38s║\n" "BBR:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "║  %-14s %-38s║\n" "Docker:" "$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')"
printf "║  %-14s %-38s║\n" "TR状态:" "$(docker inspect -f '{{.State.Status}}' transmission_jp 2>/dev/null)"
printf "║  %-14s %-38s║\n" "FG状态:" "$(docker inspect -f '{{.State.Status}}' flexget_jp 2>/dev/null)"
printf "║  %-14s %-38s║\n" "磁盘使用:" "$(df -h ${DEPLOY_DIR}/${NODE_NAME}/data 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
printf "║  %-14s %-38s║\n" "Sparse:" "$(cd ${DEPLOY_DIR} && git sparse-checkout list 2>/dev/null | tr '\n' ', ')"
echo "║                                                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  📌 日常运维命令:                                    ║"
echo "║    容器状态:  docker ps                              ║"
echo "║    TR资源:    docker stats transmission_jp --no-stream║"
echo "║    TR日志:    docker logs transmission_jp --tail 50   ║"
echo "║    FG日志:    docker logs flexget_jp --tail 50        ║"
echo "║    FG手动执行: docker exec flexget_jp flexget execute ║"
echo "║    磁盘监控:  df -h /home/BT/PT_JP/data               ║"
echo "║    拉取更新:  cd /home/BT && git pull origin main     ║"
echo "║    重启全部:  cd /home/BT/PT_JP && docker compose restart ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

info "部署完成！Transmission + FlexGet 已开始自动运行"