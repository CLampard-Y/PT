# PT — 全球保种服务器管理仓库

## 项目简介

基于 **Monorepo** 架构管理全球多节点 PT 保种服务器，采用 **Git Sparse Checkout** 技术实现各节点配置隔离。

## 仓库结构

```
PT/
├── common_scripts/        # 所有节点通用的脚本
│   ├── init_env.sh        # 环境初始化 (Docker, BBR, Tools)
│   └── sysctl_optim.conf  # 内核参数配置文件
├── PT_JP/                 # 日本节点
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── config/
│   └── scripts/
├── PT_US/                 # 美国节点 (占位)
└── PT_HK/                 # 香港节点 (占位)
```

## 部署方式

各节点 VPS 使用 Sparse Checkout 只拉取所需目录：

```bash
git init
git remote add origin <REPO_URL>
git sparse-checkout init --cone
git sparse-checkout set common_scripts PT_JP   # 日本节点示例
git pull origin main
```

## 客户端

- **qBittorrent Official 4.6.7** (MT白名单合规)
- 禁止使用 Enhanced Edition

## 核心策略

- 长期挂载 3000-5000 个小体积种子
- 目标：刷平均做种时间
- 内置 RSS 自动下载 Free + 小体积种子