#!/usr/bin/env bash
# ===========================================================
#  PT_JP 日本节点 — 容器部署与配置脚本
#
#  前置条件: 已运行 bootstrap.sh 完成环境初始化并重启
#  执行方式: cd /home/pt/PT_JP && sudo bash scripts/deploy.sh
#
#  本脚本负责:
#    阶段 D: 启动 qBittorrent 容器
#    阶段 E: 覆盖性能配置
#    阶段 F: 指导 RSS 配置
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
DEPLOY_DIR="/home/pt"
NODE_NAME="PT_JP"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       PT_JP 日本节点 — 容器部署                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  目录:   ${DEPLOY_DIR}/${NODE_NAME}"
echo "║  客户端: qBittorrent 4.6.7 Official"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ===================== 前置环境检查 =====================
# 确认 bootstrap.sh 已经运行过
if ! command -v docker &>/dev/null; then
    error "Docker 未安装！请先运行 bootstrap.sh:\n  sudo bash /home/pt/common_scripts/bootstrap.sh"
fi

if [[ ! -d "${DEPLOY_DIR}/${NODE_NAME}" ]]; then
    error "${DEPLOY_DIR}/${NODE_NAME} 不存在！请先运行 bootstrap.sh"
fi

info "前置检查通过: Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"

# =============================================================
#  阶段 D: 启动 qBittorrent 容器
# =============================================================
phase "D" "启动 qBittorrent 容器"

cd "${DEPLOY_DIR}/${NODE_NAME}"

# 创建数据目录
mkdir -p ./data/complete ./data/incomplete
info "数据目录已创建: ./data/complete, ./data/incomplete"

# 创建 .env 文件
if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        cp .env.example .env
        warn ".env 已从模板创建，请务必编辑填入真实密码和 Passkey!"
        warn "执行: vim ${DEPLOY_DIR}/${NODE_NAME}/.env"
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

# ⚠️ 关键: 备份仓库预置配置 (容器首次启动会覆盖它!)
QB_CONF_REPO="./config/qBittorrent/qBittorrent.conf"
QB_CONF_BACKUP="/tmp/qBittorrent.conf.repo_preset"
if [[ -f "${QB_CONF_REPO}" ]]; then
    cp "${QB_CONF_REPO}" "${QB_CONF_BACKUP}"
    info "已备份仓库预置配置到 ${QB_CONF_BACKUP}"
fi

# 首次启动容器 (会生成默认配置，覆盖仓库预置)
info "首次启动容器 (生成默认配置)..."
docker compose up -d

info "等待容器初始化 (15秒)..."
sleep 15

# 获取初始密码
echo ""
echo "  ┌──────────────────────────────────────────┐"
echo "  │  📋 qBittorrent 初始登录信息             │"
echo "  ├──────────────────────────────────────────┤"
INIT_PASS=$(docker logs qbittorrent_jp 2>&1 | grep -oP 'temporary password.*: \K.*' || echo '请查看容器日志')
printf "  │  地址: http://%-27s│\n" "$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo '你的IP'):8080"
echo "  │  用户: admin                             │"
printf "  │  密码: %-33s│\n" "${INIT_PASS}"
echo "  │                                          │"
echo "  │  ⚠️  请立即登录并修改密码！              │"
echo "  └──────────────────────────────────────────┘"
echo ""

# 验证容器状态
if docker ps --format '{{.Names}}' | grep -q 'qbittorrent_jp'; then
    info "容器运行正常 ✓"
else
    error "容器启动失败，请检查: docker logs qbittorrent_jp"
fi

# =============================================================
#  阶段 E: 覆盖性能配置
# =============================================================
phase "E" "覆盖 qBittorrent 性能配置"

# ⚠️ 核心逻辑:
#   容器首次启动会在 ./config/qBittorrent/ 下生成默认 qBittorrent.conf
#   我们需要用仓库预置的优化配置覆盖它
#   流程: 停止容器 → 恢复备份 → 重新启动

QB_CONF="./config/qBittorrent/qBittorrent.conf"

if [[ -f "${QB_CONF_BACKUP}" ]]; then
    info "检测到仓库预置配置备份"

    # 停止容器 (运行中修改配置会被覆盖)
    info "停止容器..."
    docker compose stop
    sleep 3
    
    # 用仓库预置配置覆盖容器生成的默认配置
    cp "${QB_CONF_BACKUP}" "${QB_CONF}"
    info "已用仓库预置配置覆盖默认配置"
    rm -f "${QB_CONF_BACKUP}"

    # 重新启动
    info "重新启动容器..."
    docker compose up -d
    sleep 10

    # 验证关键参数
    if grep -q 'MaxActiveTorrents=-1' "${QB_CONF}" 2>/dev/null; then
        info "做种无限制 (-1) ✓"
    fi
    if grep -q 'MaxActiveDownloads=5' "${QB_CONF}" 2>/dev/null; then
        info "下载队列限制 5 ✓"
    fi
    if grep -q 'GlobalUPSpeedLimit=4096' "${QB_CONF}" 2>/dev/null; then
        info "上传限速 4MB/s ✓"
    fi
    if grep -q 'DiskIOReadMode=0' "${QB_CONF}" 2>/dev/null; then
        info "磁盘IO模式 (OS Cache) ✓"
    fi

    # ⚠️ 覆盖配置后密码哈希丢失，qB会生成新临时密码
    # 必须重新获取并显示给用户
    NEW_PASS=$(docker logs qbittorrent_jp 2>&1 | grep -oP 'temporary password.*: \K.*' | tail -1 || echo '请查看容器日志')
    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │  ⚠️  配置覆盖后密码已更新！              │"
    echo "  ├──────────────────────────────────────────┤"
    printf "  │  新密码: %-33s│\n" "${NEW_PASS}"
    echo "  │  请用此密码登录 WebUI                   │"
    echo "  └──────────────────────────────────────────┘"
    echo ""

    info "性能配置覆盖完成，容器已重启 ✓"
else
    warn "未找到预置配置备份，请手动编辑: vim ${QB_CONF}"
    warn "修改后执行: docker compose restart"
fi

# =============================================================
#  阶段 F: 配置 RSS 自动下载 (WebUI 手动操作)
# =============================================================
phase "F" "配置 RSS 自动下载"

echo "  RSS 配置需要在 WebUI 中手动完成，步骤如下:"
echo ""
echo "  1. 浏览器打开 WebUI 并登录"
echo ""
echo "  2. 添加 RSS 源:"
echo "     View → RSS → New subscription"
echo "     URL: 粘贴 .env 中的 MT_RSS_URL"
echo "     (https://kp.m-team.cc/api/rss/dl?passkey=xxx&https=1&spstate=2)"
echo ""
echo "  3. 创建自动下载规则:"
echo "     RSS → RSS Downloader (扳手图标) → '+'"
echo "     规则名:    MT-Free-SmallSeed"
echo "     Size min:  1 MB"
echo "     Size max:  500 MB"
echo "     Category:  seed_farming"
echo "     Save to:   /downloads/complete"
echo "     Apply to:  ☑ 你的MT RSS源"
echo "     ☑ Enable Rule"
echo ""
echo "  4. 验证 Options → Downloads:"
echo "     ☑ 磁盘剩余空间低于 20480 MB 时停止下载"
echo ""
echo "  5. ⚠️  修改密码后，回填到 .env 文件:"
echo "     vim ${DEPLOY_DIR}/${NODE_NAME}/.env"
echo "     将 QB_PASS=CHANGE_ME_AFTER_FIRST_LOGIN 改为你的新密码"
echo "     (磁盘守护脚本需要此密码调用紧急暂停API)"
echo ""
warn "请在 WebUI 中完成以上 RSS 配置后继续"
read -rp "RSS 已配置完成？(y/N): " RSS_DONE
[[ "${RSS_DONE}" == "y" || "${RSS_DONE}" == "Y" ]] && \
    info "RSS 配置已确认" || \
    warn "请稍后手动完成 RSS 配置"

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
printf "║  %-14s %-38s║\n" "容器状态:" "$(docker inspect -f '{{.State.Status}}' qbittorrent_jp 2>/dev/null)"
printf "║  %-14s %-38s║\n" "内存限制:" "$(docker inspect -f '{{.HostConfig.Memory}}' qbittorrent_jp 2>/dev/null | awk '{printf "%.0fGB", $1/1024/1024/1024}')"
printf "║  %-14s %-38s║\n" "磁盘使用:" "$(df -h ${DEPLOY_DIR}/${NODE_NAME}/data 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
printf "║  %-14s %-38s║\n" "Sparse:" "$(cd ${DEPLOY_DIR} && git sparse-checkout list 2>/dev/null | tr '\n' ', ')"
echo "║                                                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  📌 日常运维命令:                                    ║"
echo "║    查看状态:  docker ps                              ║"
echo "║    查看资源:  docker stats qbittorrent_jp --no-stream║"
echo "║    查看日志:  docker logs qbittorrent_jp --tail 50   ║"
echo "║    磁盘监控:  df -h /home/pt/PT_JP/data              ║"
echo "║    拉取更新:  cd /home/pt && git pull origin main    ║"
echo "║    重启服务:  cd /home/pt/PT_JP && docker compose restart ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

info "建议重启一次 VPS 使所有内核参数完全生效: sudo reboot"