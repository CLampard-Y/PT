#!/usr/bin/env bash
# ===========================================================
#  PT_JP 日本节点 — 部署验证脚本
#  用法: bash PT_JP/scripts/verify.sh
#  功能: 一键检查所有组件是否正常运行
# ===========================================================
set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[✓]${NC} $*"; }
fail() { echo -e "  ${RED}[✗]${NC} $*"; ERRORS=$((ERRORS+1)); }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }

ERRORS=0
DEPLOY_DIR="/home/pt"
NODE_DIR="${DEPLOY_DIR}/PT_JP"

echo ""
echo "========== PT_JP 部署验证 =========="
echo ""

# ===== 1. 系统层 =====
echo "--- 系统层 ---"

BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
[[ "${BBR}" == "bbr" ]] && pass "BBR: ${BBR}" || fail "BBR: ${BBR} (期望 bbr)"

FILEMAX=$(sysctl -n fs.file-max 2>/dev/null)
[[ ${FILEMAX} -ge 1048576 ]] && pass "file-max: ${FILEMAX}" || fail "file-max: ${FILEMAX} (期望 >= 1048576)"

ULIMIT_N=$(ulimit -n 2>/dev/null)
[[ ${ULIMIT_N} -ge 1048576 ]] && pass "ulimit -n: ${ULIMIT_N}" || warn "ulimit -n: ${ULIMIT_N} (期望 1048576，重新登录后生效)"

SWAP=$(free -h 2>/dev/null | awk '/Swap/{print $2}')
[[ "${SWAP}" != "0B" && -n "${SWAP}" ]] && pass "Swap: ${SWAP}" || warn "Swap: 未启用"

TZ_VAL=$(timedatectl show --property=Timezone --value 2>/dev/null)
[[ "${TZ_VAL}" == "Asia/Shanghai" ]] && pass "时区: ${TZ_VAL}" || warn "时区: ${TZ_VAL} (期望 Asia/Shanghai)"

echo ""

# ===== 2. Docker 层 =====
echo "--- Docker 层 ---"

if command -v docker &>/dev/null; then
    pass "Docker: $(docker --version | grep -oP '\d+\.\d+\.\d+')"
else
    fail "Docker: 未安装"
fi

if docker compose version &>/dev/null; then
    pass "Compose: $(docker compose version --short)"
else
    fail "Docker Compose: 未安装"
fi

TR_STATUS=$(docker inspect -f '{{.State.Status}}' transmission_jp 2>/dev/null || echo "not_found")
[[ "${TR_STATUS}" == "running" ]] && pass "Transmission: ${TR_STATUS}" || fail "Transmission: ${TR_STATUS} (期望 running)"

FG_STATUS=$(docker inspect -f '{{.State.Status}}' flexget_jp 2>/dev/null || echo "not_found")
[[ "${FG_STATUS}" == "running" ]] && pass "FlexGet: ${FG_STATUS}" || warn "FlexGet: ${FG_STATUS}"

if [[ "${TR_STATUS}" == "running" ]]; then
    ULIMIT_CONTAINER=$(docker exec transmission_jp sh -c 'ulimit -n' 2>/dev/null || echo "0")
    [[ ${ULIMIT_CONTAINER} -ge 1048576 ]] && pass "容器ulimit: ${ULIMIT_CONTAINER}" || warn "容器ulimit: ${ULIMIT_CONTAINER}"
fi

echo ""

# ===== 3. 存储层 =====
echo "--- 存储层 ---"

DATA_DIR="${NODE_DIR}/data"
if [[ -d "${DATA_DIR}" ]]; then
    DISK_USE=$(df -h "${DATA_DIR}" 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
    DISK_PCT=$(df "${DATA_DIR}" 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $5}')
    if [[ -n "${DISK_PCT}" ]]; then
        [[ ${DISK_PCT} -lt 80 ]] && pass "磁盘使用: ${DISK_USE}" || warn "磁盘使用: ${DISK_USE} (偏高!)"
    else
        warn "磁盘使用: 无法获取"
    fi

    INODE_USE=$(df -ih "${DATA_DIR}" 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
    INODE_PCT=$(df -i "${DATA_DIR}" 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $5}')
    if [[ -n "${INODE_PCT}" ]]; then
        [[ ${INODE_PCT} -lt 75 ]] && pass "Inode: ${INODE_USE}" || warn "Inode: ${INODE_USE} (偏高!)"
    else
        warn "Inode: 无法获取"
    fi
else
    fail "数据目录不存在: ${DATA_DIR}"
fi

echo ""

# ===== 4. 网络层 =====
echo "--- 网络层 ---"

WEBUI_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:9091/transmission/web/ 2>/dev/null)
[[ "${WEBUI_CODE}" == "200" || "${WEBUI_CODE}" == "401" ]] && \
    pass "TR WebUI: HTTP ${WEBUI_CODE}" || fail "TR WebUI: HTTP ${WEBUI_CODE} (期望 200/401)"

BT_LISTEN=$(ss -tlnp 2>/dev/null | grep ':51413' | head -1)
[[ -n "${BT_LISTEN}" ]] && pass "BT端口 51413: LISTENING" || warn "BT端口 51413: 未检测到 (可能在容器内监听)"

echo ""

# ===== 5. 自动化 =====
echo "--- 自动化 ---"

CRON_COUNT=$(crontab -l 2>/dev/null | grep -c 'disk_guard' || true)
[[ ${CRON_COUNT} -ge 1 ]] && pass "Cron磁盘守护: ${CRON_COUNT} 条规则" || warn "Cron磁盘守护: 未注册"

echo ""

# ===== 6. Git Sparse Checkout =====
echo "--- Git Sparse Checkout ---"

if [[ -d "${DEPLOY_DIR}/.git" ]]; then
    SPARSE_LIST=$(cd "${DEPLOY_DIR}" && git sparse-checkout list 2>/dev/null | tr '\n' ', ')
    [[ -n "${SPARSE_LIST}" ]] && pass "Sparse规则: ${SPARSE_LIST}" || warn "Sparse Checkout 未配置"

    # 隔离性验证
    for OTHER in PT_US PT_HK; do
        if [[ -d "${DEPLOY_DIR}/${OTHER}" ]] && \
           [[ -n "$(find "${DEPLOY_DIR}/${OTHER}" -mindepth 1 -not -name '.gitkeep' 2>/dev/null)" ]]; then
            fail "${OTHER}: 存在非占位文件 (隔离失败!)"
        else
            pass "${OTHER}: 已隔离 ✓"
        fi
    done
else
    warn "${DEPLOY_DIR} 不是 Git 仓库"
fi

# ===== 结果汇总 =====
echo ""
echo "=========================================="
if [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${GREEN}  ✅ 全部检查通过！共 0 个错误${NC}"
else
    echo -e "${RED}  ❌ 发现 ${ERRORS} 个错误，请检查上方标记 [✗] 的项目${NC}"
fi
echo "=========================================="
echo ""