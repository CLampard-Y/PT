#!/usr/bin/env bash
# ===========================================================
#  PT_JP 日本节点 — 容器部署与配置脚本 (生产级重构版)
#
#  前置条件:
#    1. Server-Ops 已完成系统初始化 (Docker/BBR/SSH)
#    2. bootstrap.sh 已拉取 PT 业务代码
#  执行方式: cd /home/BT/PT_JP && sudo bash scripts/deploy.sh
#
#  设计原则:
#    - 幂等性: 可重复运行，不破坏已有配置
#    - 权限安全: 自动检测 PUID/PGID，容器不以 root 运行
#    - 健壮性: 每步操作都有验证和回退
#
#  本脚本负责:
#    阶段 A: 环境预检 + 权限检测 (调用 init_env.sh)
#    阶段 B: 幂等生成 .env 配置
#    阶段 C: 启动 Transmission + 配置覆盖
#    阶段 D: 配置 FlexGet RSS + 启动
#    阶段 E: 注册监控任务 + 最终验证
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
NODE_DIR="${DEPLOY_DIR}/${NODE_NAME}"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       PT_JP 日本节点 — 容器部署                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  目录:   ${NODE_DIR}"
echo "║  客户端: Transmission 4.0.6 + FlexGet RSS"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# =============================================================
#  阶段 A: 环境预检 + 权限检测
# =============================================================
phase "A" "环境预检 + 权限检测"

# 调用 init_env.sh 进行预检 (Docker/权限/目录)
INIT_SCRIPT="${DEPLOY_DIR}/common_scripts/init_env.sh"
if [[ -f "${INIT_SCRIPT}" ]]; then
    source "${INIT_SCRIPT}"
else
    # 回退: 手动做最小检查
    warn "未找到 ${INIT_SCRIPT}，执行最小预检"
    command -v docker &>/dev/null || error "Docker 未安装！"
    docker compose version &>/dev/null || error "Docker Compose 未安装！"
    export PUID=${PUID:-1000}
    export PGID=${PGID:-1000}
    export TZ=${TZ:-Asia/Shanghai}
fi

if [[ ! -d "${NODE_DIR}" ]]; then
    error "${NODE_DIR} 不存在！请先运行 bootstrap.sh"
fi

info "前置检查通过: Docker $(docker --version | grep -oP '\d+\.\d+\.\d+'), PUID=${PUID}"

# =============================================================
#  阶段 B: 幂等生成 .env 配置
# =============================================================
phase "B" "幂等生成 .env 配置"

cd "${NODE_DIR}"

# ── 幂等 .env 生成逻辑 ──
# 原则: 已有的用户密钥 (TR_PASS, MT_RSS_URL) 绝不覆盖
#       仅补充缺失变量 + 更新系统变量 (PUID/PGID/TZ)

ensure_env_var() {
    # 用法: ensure_env_var "KEY" "DEFAULT_VALUE" "注释"
    local key="$1" val="$2" comment="${3:-}"
    if [[ -f .env ]] && grep -q "^${key}=" .env; then
        return 0  # 已存在，不覆盖
    fi
    # 写入注释 (去重: 避免重复运行追加相同注释)
    if [[ -n "${comment}" ]]; then
        grep -qF "# ${comment}" .env 2>/dev/null || echo "# ${comment}" >> .env
    fi
    echo "${key}=${val}" >> .env
}

update_env_var() {
    # 用法: update_env_var "KEY" "VALUE" — 强制更新 (用于系统变量)
    local key="$1" val="$2"
    if [[ -f .env ]] && grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
        echo "${key}=${val}" >> .env
    fi
}

if [[ ! -f .env ]]; then
    # 首次部署: 从模板创建
    if [[ -f .env.example ]]; then
        cp .env.example .env
        info ".env 已从模板创建"
    else
        touch .env
        warn ".env.example 不存在，创建空 .env"
    fi
    ENV_IS_NEW=true
else
    info ".env 已存在，执行幂等更新"
    ENV_IS_NEW=false
fi

# 强制更新系统变量 (每次部署都刷新)
update_env_var "PUID" "${PUID}"
update_env_var "PGID" "${PGID}"
update_env_var "TZ" "${TZ}"
info "系统变量已更新: PUID=${PUID} PGID=${PGID} TZ=${TZ}"

# 补充缺失的业务变量 (不覆盖已有值)
ensure_env_var "TR_USER" "admin" "Transmission RPC 用户名"
ensure_env_var "TR_PASS" "CHANGE_ME_TO_STRONG_PASSWORD" "Transmission RPC 密码 (必须修改!)"
ensure_env_var "TR_WEBUI_PORT" "9091" "Transmission WebUI 端口"
ensure_env_var "TR_PEER_PORT" "51413" "Transmission Peer 端口"
ensure_env_var "TR_IMAGE_TAG" "4.0.6" "Transmission 镜像版本"
ensure_env_var "MT_RSS_URL" "https://YOUR_TRACKER/rss?passkey=YOUR_PASSKEY_HERE" "MT RSS 地址 (必须修改!)"
ensure_env_var "FG_WEBUI_PASS" "flexget" "FlexGet WebUI 密码"

# 首次创建时提示编辑
if [[ "${ENV_IS_NEW}" == "true" ]]; then
    warn "╔══════════════════════════════════════════════╗"
    warn "║  ⚠️  首次部署，请务必编辑 .env 文件!         ║"
    warn "║  必须修改: TR_PASS, MT_RSS_URL (passkey)     ║"
    warn "╚══════════════════════════════════════════════╝"
    echo ""
    read -rp "是否现在编辑 .env？(Y/n): " EDIT_ENV
    if [[ "${EDIT_ENV}" != "n" && "${EDIT_ENV}" != "N" ]]; then
        vim .env || nano .env || vi .env
    fi
fi

# 安全检查: 关键变量不能是默认值
TR_PASS_CHECK=$(grep -oP '^TR_PASS=\K.*' .env 2>/dev/null || echo '')
if [[ "${TR_PASS_CHECK}" == "CHANGE_ME_TO_STRONG_PASSWORD" || -z "${TR_PASS_CHECK}" ]]; then
    warn "TR_PASS 仍为默认值！强烈建议修改: vim .env"
fi

info ".env 配置就绪"

# =============================================================
#  阶段 C: 启动 Transmission + 配置覆盖
# =============================================================
phase "C" "启动 Transmission + 配置覆盖"

# 备份仓库预置的 settings.json (容器首次启动会覆盖)
TR_CONF_REPO="./config/transmission/settings.json"
TR_CONF_BACKUP="${NODE_DIR}/.settings.json.repo_preset"
if [[ -f "${TR_CONF_REPO}" ]]; then
    cp "${TR_CONF_REPO}" "${TR_CONF_BACKUP}"
    info "已备份仓库预置 settings.json"
fi

# 启动 Transmission (不启动 FlexGet，避免依赖等待)
info "启动 Transmission 容器..."
docker compose up -d --no-deps transmission

info "等待 Transmission 初始化并通过健康检查..."
# 等待最多 120 秒让 Transmission 变为 healthy
WAIT_COUNT=0
MAX_WAIT=120
while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
    HEALTH_STATUS=$(docker inspect transmission_jp --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
    if [[ "${HEALTH_STATUS}" == "healthy" ]]; then
        info "Transmission 健康检查通过 ✓"
        break
    elif [[ "${HEALTH_STATUS}" == "none" ]]; then
        # 容器没有健康检查或还未开始
        if docker ps --format '{{.Names}}' | grep -q 'transmission_jp'; then
            info "Transmission 运行中 (无健康检查或启动中)，继续等待..."
        fi
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    echo -n "."
done
echo ""

if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
    warn "Transmission 健康检查超时，但容器可能仍在运行"
    warn "请检查: docker logs transmission_jp"
fi

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
#  阶段 C (续): 覆盖 Transmission 配置
# =============================================================
phase "C+" "覆盖 Transmission 配置"

# 注意: Web UI 已改用独立容器 tr-web (jianxcao/transmission-web)
# 无需手动安装 TWC，容器会自动提供现代化管理界面
info "Web UI 使用独立容器 tr-web，访问端口: ${TR_WEB_PORT:-7632}"

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
#  阶段 D: 配置 FlexGet RSS 变量 + 启动
# =============================================================
phase "D" "配置 FlexGet RSS"

# 从 .env 读取变量写入 FlexGet variables.yml
FG_VARS="./config/flexget/variables.yml"
MT_RSS=$(grep -oP '^MT_RSS_URL=\K.*' .env 2>/dev/null || echo '')
TR_USER_FG=$(grep -oP '^TR_USER=\K.*' .env 2>/dev/null || echo 'admin')
TR_PASS_FG=$(grep -oP '^TR_PASS=\K.*' .env 2>/dev/null || echo 'changeme')

if [[ -n "${MT_RSS}" && "${MT_RSS}" != *"YOUR_PASSKEY_HERE"* ]]; then
    cat > "${FG_VARS}" << FGEOF
# FlexGet 变量文件 (由 deploy.sh 自动生成)
# Transmission RPC 认证
tr_user: ${TR_USER_FG}
tr_pass: ${TR_PASS_FG}

# MT站 RSS 地址
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
echo "  - 每30分钟自动抓取 MT Free 种子 (< 12MB)"
echo "  - 自动推送到 Transmission 下载"
echo "  - 无需手动配置 RSS 规则 ✓"
echo ""

# 启动 Transmission Web UI
info "启动 Transmission Web UI 容器..."
docker compose up -d tr-web
sleep 5

if docker ps --format '{{.Names}}' | grep -q 'tr-web_jp'; then
    info "Transmission Web UI 容器运行正常 ✓"
    info "访问地址: http://服务器IP:${TR_WEB_PORT:-7632}"
else
    warn "Transmission Web UI 启动失败，请检查: docker logs tr-web_jp"
fi

echo ""

# =============================================================
#  阶段 E: 注册监控任务 + 健康检查 + 最终验证
# =============================================================
phase "E" "注册监控任务 & 最终验证"

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

# ── 健康检查 ──
info "执行健康检查..."

# Transmission WebUI
if command -v curl &>/dev/null; then
    TR_PORT=$(grep -oP '^TR_WEBUI_PORT=\K.*' .env 2>/dev/null || echo '9091')
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${TR_PORT}/transmission/web/" 2>/dev/null || echo '000')
    if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "401" ]]; then
        info "Transmission WebUI: HTTP ${HTTP_CODE} ✓"
    else
        warn "Transmission WebUI: HTTP ${HTTP_CODE} (可能仍在启动中)"
    fi
else
    warn "curl 不可用，跳过 HTTP 健康检查"
fi

# Docker 容器状态
for cname in transmission_jp flexget_jp; do
    local_status=$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || echo 'not_found')
    if [[ "${local_status}" == "running" ]]; then
        info "${cname}: ${local_status} ✓"
    else
        warn "${cname}: ${local_status}"
    fi
done

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
printf "║  %-14s %-38s║\n" "WebUI状态:" "$(docker inspect -f '{{.State.Status}}' tr-web_jp 2>/dev/null)"
printf "║  %-14s %-38s║\n" "磁盘使用:" "$(df -h ${DEPLOY_DIR}/${NODE_NAME}/data 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
printf "║  %-14s %-38s║\n" "PUID/PGID:" "${PUID}/${PGID}"
printf "║  %-14s %-38s║\n" "TZ:" "${TZ}"
echo "║                                                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  🌐 Web 访问地址:                                    ║"
echo "║    Transmission Web UI: http://服务器IP:${TR_WEB_PORT:-7632}    ║"
echo "║    FlexGet Web UI:      http://服务器IP:5050         ║"
echo "║                                                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  📌 日常运维命令:                                    ║"
echo "║    容器状态:  docker ps                              ║"
echo "║    TR资源:    docker stats transmission_jp --no-stream║"
echo "║    TR日志:    docker logs transmission_jp --tail 50   ║"
echo "║    FG日志:    docker logs flexget_jp --tail 50        ║"
echo "║    WebUI日志: docker logs tr-web_jp --tail 50        ║"
echo "║    FG手动执行: docker exec flexget_jp flexget execute ║"
echo "║    磁盘监控:  df -h /home/BT/PT_JP/data               ║"
echo "║    拉取更新:  cd /home/BT && git pull origin main      ║"
echo "║    重启全部:  cd /home/BT/PT_JP && docker compose restart ║"
echo "║                                                      ║"
echo "║  🗑️  完整卸载 (零残留):                              ║"
echo "║    cd /home/BT/PT_JP && sudo bash scripts/uninstall.sh║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

info "部署完成！Transmission + FlexGet 已开始自动运行"