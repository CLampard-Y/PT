#!/usr/bin/env bash
# ===========================================================
#  磁盘 & Inode 守护脚本 (qBittorrent 版)
#
#  qBittorrent 已有原生磁盘空间预留 (20GB)，本脚本补充:
#    1. Inode 监控 (原生不支持)
#    2. 磁盘使用率日志记录
#    3. 极端情况下的紧急暂停
#
#  部署: crontab → */5 * * * * /path/to/disk_guard.sh
# ===========================================================
set -euo pipefail

# ===================== 配置 =====================
DATA_DIR="/home/pt/PT_JP/data"
INODE_WARN_PERCENT=75
DISK_EMERGENCY_PERCENT=90
LOG_FILE="/var/log/pt-disk-guard.log"

# qBittorrent WebUI API
QB_URL="http://127.0.0.1:8080"
QB_USER="admin"
QB_PASS="你的WebUI密码"       # ← 部署时修改

# ===================== 函数 =====================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

qb_login() {
    # 登录获取Cookie
    COOKIE_FILE="/tmp/.qb_cookie"
    curl -s -c "${COOKIE_FILE}" \
        "${QB_URL}/api/v2/auth/login" \
        -d "username=${QB_USER}&password=${QB_PASS}" \
        > /dev/null 2>&1
}

qb_pause_all() {
    qb_login
    curl -s -b "/tmp/.qb_cookie" \
        "${QB_URL}/api/v2/torrents/pause" \
        -d "hashes=all" > /dev/null 2>&1
}

# ===================== 检查 =====================
# 确保数据目录存在
if [[ ! -d "${DATA_DIR}" ]]; then
    log "⚠️  数据目录 ${DATA_DIR} 不存在，跳过检查"
    exit 0
fi

# 磁盘使用率
DISK_PCT=$(df "${DATA_DIR}" 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $5}')
# Inode 使用率
INODE_PCT=$(df -i "${DATA_DIR}" 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $5}')
# 文件数量
FILE_COUNT=$(find "${DATA_DIR}" -type f 2>/dev/null | wc -l)
# 剩余空间 (MB)
FREE_MB=$(df -m "${DATA_DIR}" 2>/dev/null | awk 'NR==2{print $4}')

log "磁盘: ${DISK_PCT}% | 剩余: ${FREE_MB}MB | Inode: ${INODE_PCT}% | 文件: ${FILE_COUNT}"

# ---- 紧急磁盘保护 (qB原生预留的最后防线) ----
if [[ ${DISK_PCT} -ge ${DISK_EMERGENCY_PERCENT} ]]; then
    log "🚨 紧急! 磁盘 ${DISK_PCT}% >= ${DISK_EMERGENCY_PERCENT}%! 暂停所有种子!"
    qb_pause_all
    log "⏸️  已通过API暂停所有种子"
fi

# ---- Inode 保护 ----
if [[ ${INODE_PCT} -ge ${INODE_WARN_PERCENT} ]]; then
    log "⚠️  Inode ${INODE_PCT}% >= ${INODE_WARN_PERCENT}%! 请清理小文件"
fi

# ---- 日志轮转 ----
if [[ -f "${LOG_FILE}" ]]; then
    tail -1000 "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null && \
        mv "${LOG_FILE}.tmp" "${LOG_FILE}"
fi