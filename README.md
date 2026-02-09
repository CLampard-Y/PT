# PT — 全球保种服务器管理仓库

## 项目简介

基于 **Monorepo** 架构管理全球多节点 PT 保种服务器，采用 **Git Sparse Checkout** 技术实现各节点配置隔离。

> ⚠️ **本仓库仅包含 PT 业务逻辑**。系统底层初始化 (Docker, BBR, SSH 等) 已迁移到 [Server-Ops](https://github.com/<用户名>/Server-Ops) 仓库。

## 仓库结构

```
PT/
├── common_scripts/        # 通用脚本
│   └── bootstrap.sh       # 引导脚本 (Git Sparse Checkout)
├── PT_JP/                 # 日本节点
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── config/
│   └── scripts/
├── PT_US/                 # 美国节点 (占位)
└── PT_HK/                 # 香港节点 (占位)
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

## 客户端

- **Transmission 4.0.6 Official** (MT白名单合规) + **FlexGet RSS**
- 低优先级后台运行，CPU/内存严格隔离

## 核心策略

- 长期挂载 10,000+ 个极小体积种子 (10-90MB)
- 目标：刷平均做种时间
- FlexGet 自动下载 Free + 小体积种子
- 全部数据限制在 /home/BT 内，25GB 软限制

## 依赖关系

```
Server-Ops (系统底层)     ←  先执行
    └── PT (业务层)       ←  后执行
```