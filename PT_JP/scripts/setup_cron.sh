#!/usr/bin/env bash
# ===========================================================
#  注册定时任务: 磁盘/Inode 守护
#  (RSS 由 FlexGet 容器自动处理，无需 cron)
#
#  执行: sudo bash PT_JP/scripts/setup_cron.sh
# ===========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 赋予执行权限
chmod +x "${SCRIPT_DIR}/disk_guard.sh"

# 清除旧的 PT 相关 cron 任务，再添加新的
(crontab -l 2>/dev/null | grep -v 'disk_guard') | crontab -

# 确保日志目录存在
mkdir -p /home/BT/PT_JP/logs

(crontab -l 2>/dev/null; cat << EOF
# ===== PT保种 — 磁盘/Inode守护 (每5分钟) =====
*/5 * * * * ${SCRIPT_DIR}/disk_guard.sh > /dev/null 2>&1
EOF
) | crontab -

echo "✅ Crontab 已注册:"
crontab -l | grep "disk_guard"
echo ""
echo "📌 RSS 自动下载由 FlexGet 容器内置调度处理，无需额外 cron"