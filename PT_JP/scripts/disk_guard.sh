#!/usr/bin/env bash
# ===========================================================
#  磁盘 & Inode 守护脚本 (Transmission 版)
#
#  功能:
#    1. 磁盘剩余空间 < 2GB 时，调用 transmission-remote 暂停所有任务
#    2. Inode 使用率监控
#    3. 磁盘使用率日志记录
#
#  部署: crontab → */5 * * * * /path/to/disk_guard.sh
# ===========================================================
set -uo pipefail

# ===================== 配置 =====================
DATA_DIR="/home/BT/PT_JP/data"
LOG_DIR="/home/BT/PT_JP/logs"
FREE_MB_THRESHOLD=2048
INODE_WARN_PERCENT=75

# 日志和标记文件全部封闭在 /home/BT 内 (零泄漏策略)
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/disk-guard.log"
PAUSE_FLAG="${LOG_DIR}/.disk_guard_paused"

# 从 .env 文件读取 Transmission 认证信息
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
    TR_USER=$(grep -oP '^TR_USER=\K.*' "${ENV_FILE}" 2>/dev/null || echo "admin")
    TR_PASS=$(grep -oP '^TR_PASS=\K.*' "${ENV_FILE}" 2>/dev/null || echo "")
else
    TR_USER="admin"
    TR_PASS=""
fi

TR_AUTH="${TR_USER}:${TR_PASS}"
TR_HOST="127.0.0.1:9091"

# ===================== 函数 =====================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

tr_stop_all() {
    # 优先使用宿主机的 transmission-remote
    if command -v transmission-remote &>/dev/null; then
        transmission-remote "${TR_HOST}" --auth "${TR_AUTH}" -t all --stop 2>/dev/null || true
    else
        # 回退: 通过 docker exec 调用容器内的命令
        docker exec transmission_jp transmission-remote localhost:9091 \
            --auth "${TR_AUTH}" -t all --stop 2>/dev/null || true
    fi
}

tr_start_all() {
    if command -v transmission-remote &>/dev/null; then
        transmission-remote "${TR_HOST}" --auth "${TR_AUTH}" -t all --start 2>/dev/null || true
    else
        docker exec transmission_jp transmission-remote localhost:9091 \
            --auth "${TR_AUTH}" -t all --start 2>/dev/null || true
    fi
}

# ===================== 检查 =====================
if [[ ! -d "${DATA_DIR}" ]]; then
    log "⚠️  数据目录 ${DATA_DIR} 不存在，跳过检查"
    exit 0
fi

# 采集指标
DISK_PCT=$(df "${DATA_DIR}" 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $5}')
INODE_PCT=$(df -i "${DATA_DIR}" 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $5}')
FILE_COUNT=$(find "${DATA_DIR}" -type f 2>/dev/null | wc -l)
FREE_MB=$(df -m "${DATA_DIR}" 2>/dev/null | awk 'NR==2{print $4}')

log "磁盘: ${DISK_PCT:-?}% | 剩余: ${FREE_MB:-?}MB | Inode: ${INODE_PCT:-?}% | 文件: ${FILE_COUNT}"

# ---- 紧急磁盘保护: 剩余 < 2GB 时暂停所有任务 ----
if [[ -n "${FREE_MB}" ]] && [[ ${FREE_MB} -le ${FREE_MB_THRESHOLD} ]]; then
    log "🚨 紧急! 剩余 ${FREE_MB}MB <= ${FREE_MB_THRESHOLD}MB! 暂停所有下载!"
    if [[ -n "${TR_PASS}" && "${TR_PASS}" != "CHANGE_ME_TO_STRONG_PASSWORD" ]]; then
        tr_stop_all
        log "⏸️  已通过 transmission-remote 暂停所有任务"
    else
        log "⚠️  TR_PASS 未配置或为默认值，无法调用RPC。请修改 .env 中的 TR_PASS"
    fi
# ---- 空间恢复: 剩余 > 5GB 时自动恢复 ----
elif [[ -n "${FREE_MB}" ]] && [[ ${FREE_MB} -gt 5120 ]]; then
    # 检查是否存在暂停标记文件
    if [[ -f "${PAUSE_FLAG}" ]]; then
        log "✅ 磁盘空间已恢复 (${FREE_MB}MB)，恢复所有任务"
        tr_start_all
        rm -f "${PAUSE_FLAG}"
    fi
fi

# 写入暂停标记 (用于恢复判断)
if [[ -n "${FREE_MB}" ]] && [[ ${FREE_MB} -le ${FREE_MB_THRESHOLD} ]]; then
    touch "${PAUSE_FLAG}"
fi

# ---- Inode 保护 ----
if [[ -n "${INODE_PCT}" ]] && [[ ${INODE_PCT} -ge ${INODE_WARN_PERCENT} ]]; then
    log "⚠️  Inode ${INODE_PCT}% >= ${INODE_WARN_PERCENT}%! 请清理小文件"
fi

# ---- Watch 目录清理: 删除超过 10 分钟的残留 .torrent 文件 ----
# 正常情况下 Transmission 几秒内就会拾取 .torrent 文件
# 超过 10 分钟说明是重复种子或无效文件，安全删除
WATCH_DIR="/home/BT/PT_JP/watch"
if [[ -d "${WATCH_DIR}" ]]; then
    STALE_COUNT=$(find "${WATCH_DIR}" -name '*.torrent' -o -name '*.torrent.added' -mmin +10 2>/dev/null | wc -l)
    if [[ ${STALE_COUNT} -gt 0 ]]; then
        find "${WATCH_DIR}" -name '*.torrent' -mmin +10 -delete 2>/dev/null
        find "${WATCH_DIR}" -name '*.torrent.added' -mmin +10 -delete 2>/dev/null
        log "🧹 已清理 ${STALE_COUNT} 个残留 .torrent 文件"
    fi
fi

# ---- 日志轮转 ----
if [[ -f "${LOG_FILE}" ]]; then
    tail -1000 "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null && \
        mv "${LOG_FILE}.tmp" "${LOG_FILE}"
fi