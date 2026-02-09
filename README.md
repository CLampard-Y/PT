# PT — 全球保种服务器管理仓库

## 项目简介

基于 **Monorepo** 架构管理全球多节点 PT 保种服务器，采用 **Git Sparse Checkout** 技术实现各节点配置隔离。

> ⚠️ **本仓库仅包含 PT 业务逻辑**。系统底层初始化 (Docker, BBR, SSH 等) 已迁移到 [Server-Ops](https://github.com/<用户名>/Server-Ops) 仓库。

## Prerequisites (前置依赖)

| 依赖 | 来源 | 说明 |
|------|------|------|
| Docker CE | Server-Ops Layer 1 | 容器运行时 |
| Docker Compose | Server-Ops Layer 1 | 容器编排 |
| jq | Server-Ops Layer 1 | JSON 配置安全编辑 |
| BBR + Sysctl | Server-Ops Layer 1 | 网络/内核优化 |
| Git >= 2.25 | Server-Ops Layer 1 | Sparse Checkout 支持 |

> 如果以上工具缺失，请先执行: `sudo bash /home/Server-Ops/setup.sh`

## 仓库结构

```
PT/
├── common_scripts/           # 通用脚本
│   ├── bootstrap.sh          # 引导脚本 (Git Sparse Checkout)
│   └── init_env.sh           # 业务环境预检 (权限/目录/PUID)
├── PT_JP/                    # 日本节点
│   ├── docker-compose.yml    # 生产级容器编排
│   ├── .env.example          # 环境变量模板
│   ├── config/               # 配置文件 (TR + FlexGet)
│   └── scripts/
│       ├── deploy.sh          # 智能部署 (幂等/PUID/健康检查)
│       ├── verify.sh          # 部署验证
│       ├── disk_guard.sh      # 磁盘守护
│       └── setup_cron.sh      # 定时任务注册
├── PT_US/                    # 美国节点 (占位)
└── PT_HK/                    # 香港节点 (占位)
```

## 从零部署 (全新 VPS)

### 第一步: 系统初始化 (Server-Ops)

```bash
apt-get update && apt-get install -y git
git clone https://github.com/<用户名>/Server-Ops.git /home/Server-Ops
sudo bash /home/Server-Ops/setup.sh
sudo reboot
```

### 第二步: 拉取 PT 业务代码

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/<用户名>/PT/main/common_scripts/bootstrap.sh)
```

或手动 Sparse Checkout:

```bash
mkdir -p /home/BT && cd /home/BT
git init
git remote add origin <REPO_URL>
git sparse-checkout init --cone
git sparse-checkout set common_scripts PT_JP
git pull origin main
```

### 第三步: 部署 PT 业务

```bash
cd /home/BT/PT_JP
sudo bash scripts/deploy.sh
```

`deploy.sh` 会自动执行:
1. **环境预检**: Docker/权限/目录验证
2. **PUID/PGID 检测**: 自动注入 .env，容器不以 root 运行
3. **幂等 .env 生成**: 不覆盖已有密钥，仅补充缺失变量
4. **容器启动**: Transmission + FlexGet
5. **健康检查**: HTTP 状态码 + 容器状态验证

## 客户端

- **Transmission 4.0.6 Official** (MT白名单合规) + **FlexGet RSS**
- 低优先级后台运行，CPU/内存严格隔离

## 核心策略

- 长期挂载 10,000+ 个极小体积种子 (10-90MB)
- 目标：刷平均做种时间
- FlexGet 自动下载 Free + 小体积种子
- 全部数据限制在 /home/BT 内，25GB 软限制

## 生产级特性

| 特性 | 说明 |
|------|------|
| **PUID/PGID** | 容器以非 root 用户运行，自动检测当前用户 |
| **Log Rotation** | Transmission 30MB / FlexGet 10MB 上限，防止撑爆磁盘 |
| **Timezone** | TZ 环境变量 + /etc/localtime 映射双保险 |
| **Healthcheck** | Transmission 自带健康检查，FlexGet 依赖启动 |
| **幂等部署** | deploy.sh 可重复运行，不破坏已有配置 |
| **资源隔离** | TR: 3.5GB 内存 + 3 CPU / FG: 256MB + 1 CPU |

## Troubleshooting (故障排查)

### 查看容器日志

```bash
# Transmission 日志 (最近 100 行)
docker logs transmission_jp --tail 100

# FlexGet 日志
docker logs flexget_jp --tail 100

# 实时跟踪日志
docker logs -f transmission_jp
```

### 常见问题

**Q: 容器启动后立即退出**
```bash
# 检查容器退出原因
docker inspect transmission_jp --format='{{.State.ExitCode}} {{.State.Error}}'
# 检查权限问题
ls -la /home/BT/PT_JP/config/
# 修复权限 (PUID/PGID 应与 .env 中一致)
chown -R 1000:1000 /home/BT/PT_JP/config/ /home/BT/PT_JP/data/
```

**Q: Transmission WebUI 无法访问**
```bash
# 检查端口监听
ss -tlnp | grep 9091
# 检查容器健康状态
docker inspect transmission_jp --format='{{.State.Health.Status}}'
# 检查防火墙
ufw status
```

**Q: FlexGet 不抓取 RSS**
```bash
# 手动执行一次
docker exec flexget_jp flexget execute
# 检查 variables.yml 是否正确
cat /home/BT/PT_JP/config/flexget/variables.yml
```

**Q: 磁盘空间不足**
```bash
# 查看磁盘使用
df -h /home/BT/PT_JP/data
# 查看日志占用 (已有 rotation，通常不是问题)
docker system df
# 手动清理 Docker 缓存
docker system prune -f
```

### 日常运维命令

```bash
# 容器状态
docker ps
# 资源占用
docker stats transmission_jp flexget_jp --no-stream
# 重启全部
cd /home/BT/PT_JP && docker compose restart
# 拉取仓库更新
cd /home/BT && git pull origin main
# 部署验证
bash /home/BT/PT_JP/scripts/verify.sh
```

## 依赖关系

```
Server-Ops (系统底层)     ←  先执行
    └── PT (业务层)       ←  后执行
```

## 目录约定

| 路径 | 用途 |
|------|------|
| `/home/Server-Ops/` | 系统初始化仓库 (只读参考) |
| `/home/BT/` | PT 业务代码 + 运行数据 |
| `/home/BT/PT_JP/config/` | 容器配置文件 |
| `/home/BT/PT_JP/data/` | 下载数据 |
| `/home/BT/PT_JP/.env` | 环境变量 (含密钥，不入 Git) |