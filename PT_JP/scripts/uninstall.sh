#!/usr/bin/env bash
# ===========================================================
#  PT_JP 日本节点 — 完整卸载脚本
#
#  功能: 确保 docker compose down + rm -rf /home/BT 后
#        系统零残留 (100% 数据封闭)
#
#  用法: cd /home/BT/PT_JP && sudo bash scripts/uninstall.sh
#
#  清理范围:
#    1. 停止并移除所有容器 + 网络
#    2. 清理 Docker 镜像 (可选)
#    3. 清理 Crontab 中的 PT 相关条目
#    4. 删除 /home/BT 目录
# ===========================================================
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "请使用 root 权限运行: sudo bash $0"

NODE_DIR="/home/BT/PT_JP"
BT_HOME="/home/BT"

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║${NC}  ${BOLD}⚠️  PT_JP 完整卸载${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║${NC}  此操作将:"
echo -e "${RED}║${NC}    1. 停止并删除所有 PT 容器"
echo -e "${RED}║${NC}    2. 清理 Crontab 定时任务"
echo -e "${RED}║${NC}    3. 删除 ${BT_HOME} 及所有数据"
echo -e "${RED}║${NC}"
echo -e "${RED}║${NC}  ${YELLOW}所有种子数据将永久丢失！${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "确认卸载？输入 YES 继续: " CONFIRM
[[ "${CONFIRM}" != "YES" ]] && { echo "已取消"; exit 0; }

# =============================================================
#  Step 1: 停止并移除容器 + 网络
# =============================================================
echo ""
echo -e "${CYAN}━━━ Step 1/4: 停止容器 ━━━${NC}"

if [[ -f "${NODE_DIR}/docker-compose.yml" ]]; then
    cd "${NODE_DIR}"
    docker compose down --remove-orphans 2>/dev/null && \
        info "容器已停止并移除" || \
        warn "docker compose down 执行异常 (容器可能已停止)"
else
    warn "docker-compose.yml 不存在，尝试手动清理容器..."
    for cname in transmission_jp flexget_jp; do
        docker rm -f "${cname}" 2>/dev/null && info "已移除 ${cname}" || true
    done
    # 手动清理网络
    docker network rm pt_network 2>/dev/null && info "已移除 pt_network" || true
fi

# =============================================================
#  Step 2: 清理 Docker 镜像 (可选)
# =============================================================
echo ""
echo -e "${CYAN}━━━ Step 2/4: Docker 镜像清理 ━━━${NC}"

read -rp "是否同时删除 PT 相关 Docker 镜像？(y/N): " RM_IMAGES
if [[ "${RM_IMAGES}" == "y" || "${RM_IMAGES}" == "Y" ]]; then
    for img in \
        "lscr.io/linuxserver/transmission" \
        "ghcr.io/flexget/flexget"; do
        docker rmi $(docker images "${img}" -q) 2>/dev/null && \
            info "已删除镜像: ${img}" || \
            warn "镜像 ${img} 不存在或删除失败"
    done
    info "Docker 镜像清理完成"
else
    warn "跳过镜像清理 (镜像仍保留在 /var/lib/docker/)"
fi

# =============================================================
#  Step 3: 清理 Crontab
# =============================================================
echo ""
echo -e "${CYAN}━━━ Step 3/4: 清理 Crontab ━━━${NC}"

CRON_BEFORE=$(crontab -l 2>/dev/null | grep -c 'disk_guard\|PT_JP\|/home/BT' || true)
if [[ ${CRON_BEFORE} -gt 0 ]]; then
    crontab -l 2>/dev/null | grep -v 'disk_guard\|PT_JP\|/home/BT' | crontab -
    CRON_AFTER=$(crontab -l 2>/dev/null | grep -c 'disk_guard\|PT_JP\|/home/BT' || true)
    info "已清理 ${CRON_BEFORE} 条 PT 相关 cron 条目 (剩余 ${CRON_AFTER})"
else
    info "Crontab 中无 PT 相关条目"
fi

# =============================================================
#  Step 4: 删除数据目录
# =============================================================
echo ""
echo -e "${CYAN}━━━ Step 4/4: 删除数据目录 ━━━${NC}"

# 切出目标目录再删除
cd /tmp

if [[ -d "${BT_HOME}" ]]; then
    rm -rf "${BT_HOME}"
    info "已删除 ${BT_HOME}"
else
    info "${BT_HOME} 已不存在"
fi

# =============================================================
#  验证: 零残留确认
# =============================================================
echo ""
echo -e "${CYAN}━━━ 残留扫描 ━━━${NC}"

RESIDUE=0

# 检查目录
[[ -d "${BT_HOME}" ]] && { warn "残留目录: ${BT_HOME}"; RESIDUE=$((RESIDUE+1)); }

# 检查容器
for cname in transmission_jp flexget_jp; do
    docker inspect "${cname}" &>/dev/null && { warn "残留容器: ${cname}"; RESIDUE=$((RESIDUE+1)); }
done

# 检查网络
docker network inspect pt_network &>/dev/null && { warn "残留网络: pt_network"; RESIDUE=$((RESIDUE+1)); }

# 检查 crontab
CRON_RESIDUE=$(crontab -l 2>/dev/null | grep -c 'disk_guard\|PT_JP\|/home/BT' || true)
[[ ${CRON_RESIDUE} -gt 0 ]] && { warn "残留 cron: ${CRON_RESIDUE} 条"; RESIDUE=$((RESIDUE+1)); }

# 检查 Docker volumes
VOL_RESIDUE=$(docker volume ls -q 2>/dev/null | grep -ci 'pt_jp\|transmission\|flexget' || true)
[[ ${VOL_RESIDUE} -gt 0 ]] && { warn "残留 volume: ${VOL_RESIDUE} 个"; RESIDUE=$((RESIDUE+1)); }

echo ""
if [[ ${RESIDUE} -eq 0 ]]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ 卸载完成！系统零残留 (0 residues)               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  发现 ${RESIDUE} 处残留，请手动检查上方警告        ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
fi
echo ""