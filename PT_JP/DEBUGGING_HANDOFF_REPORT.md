# FlexGet 种子下载故障排查交接报告
## Debugging Handoff Report

**日期**: 2026-02-11  
**项目**: PT_JP - Private Tracker 自动化下载系统  
**报告人**: Technical Project Manager & QA Lead

---

## 1. Project Context (项目背景)

### 环境信息
- **操作系统**: Debian 12 (Linux)
- **容器化**: Docker Compose
- **RSS 自动化**: FlexGet 3.11 (ghcr.io/flexget/flexget:3.11)
- **下载客户端**: Transmission 4.0.6 (lscr.io/linuxserver/transmission:4.0.6)
- **Tracker**: M-Team (馒头) Private Tracker
- **RSS Feed**: `https://rss.m-team.cc/api/rss/fetch?...`

### 项目目标
实现从 M-Team RSS feed 自动抓取种子并推送到 Transmission 下载，满足以下需求：
1. 每 30 分钟自动检查 RSS
2. 遵守 API 速率限制（1000次/天下载，100次/小时，1000次/24h搜索）
3. 种子大小限制：0.0001 MB - 12 MB
4. 每次最多下载 20 个种子
5. 优先下载新种子，如果新种子不足 20 个，则用失败种子填补空缺
6. 自动重试失败的种子

### 文件结构
```
PT_JP/
├── config/
│   ├── flexget/
│   │   ├── config.yml          # FlexGet 主配置文件
│   │   └── variables.yml       # 自动生成的变量文件
│   └── transmission/           # Transmission 配置目录
├── scripts/
│   └── deploy.sh              # 部署脚本
├── docker-compose.yml         # Docker 编排文件
└── .env                       # 环境变量（用户配置）
```

---

## 2. Problem Description (故障描述)

### 核心问题
FlexGet 在下载种子文件并推送到 Transmission 时，**间歇性出现大量失败**，错误信息为：

```
ERROR transmission mt_free_seed Error adding [种子名称] to transmission. 
TransmissionError: Query failed with result "unrecognized info".
```

### 故障特征
1. **初期正常**：重启 FlexGet 后，前 3-4 个调度周期（约 1.5-2 小时）能正常下载种子
2. **突然批量失败**：之后突然出现大量种子下载失败，错误率接近 100%
3. **失败种子不重试**：失败的种子被 `seen` 插件标记，后续不再尝试
4. **RSS feed 仍有大量未下载种子**：用户确认 RSS 中有很多符合条件的种子未被下载

### 典型日志示例
```
2026-02-10 19:45:09 INFO  download  mt_free_seed  Downloading: AiJiYanHou TXT
2026-02-10 19:45:09 INFO  download  mt_free_seed  Downloading: BuSiZhiLiXiaoLong TXT
2026-02-10 19:45:09 INFO  download  mt_free_seed  Downloading: LaoZiShiBaJiang EPUB
...
2026-02-10 19:45:12 ERROR transmission mt_free_seed Error adding AiJiYanHou TXT to transmission. 
                                                     TransmissionError: Query failed with result "unrecognized info".
2026-02-10 19:45:12 ERROR entry       mt_free_seed Failed AiJiYanHou TXT (Error adding AiJiYanHou TXT to transmission...)
2026-02-10 19:45:15 ERROR transmission mt_free_seed Error adding BuSiZhiLiXiaoLong TXT to transmission. 
                                                     TransmissionError: Query failed with result "unrecognized info".
...
2026-02-10 19:45:25 INFO  task        mt_free_seed Plugin retry_failed has requested task to be run again after execution has completed.
2026-02-10 19:45:25 INFO  task        mt_free_seed Rerunning the task in case better resolution can be achieved.
```

---

## 3. Root Cause Analysis (已进行的分析)

### 3.1 "unrecognized info" 错误的含义
- **Transmission 错误代码**：表示种子文件的 `info` 字典无法被解析
- **可能原因**：
  1. 种子文件损坏或不完整
  2. 种子文件下载过程中被截断
  3. 种子文件包含非标准字段或格式错误
  4. Tracker 返回了错误的种子数据

### 3.2 为什么初期正常，后期失败？
**假设 1：速率限制触发反爬机制**
- FlexGet 同时下载多个种子文件时，触发 M-Team 的反爬虫机制
- Tracker 返回错误的种子数据或截断响应

**假设 2：网络连接问题**
- 长时间运行后，网络连接不稳定导致种子文件下载不完整

**假设 3：种子文件本身问题**
- 某些特定种子（如 TXT、EPUB 格式）的元数据包含特殊字符
- 这些字符在 HTTP 传输过程中被破坏

### 3.3 已排除的原因
- ❌ **配置语法错误**：已通过多次测试验证配置文件语法正确
- ❌ **Transmission 连接问题**：Transmission 容器运行正常，healthcheck 通过
- ❌ **磁盘空间不足**：`free_space` 插件设置为保留 25GB，空间充足
- ❌ **种子大小超限**：`content_size` 过滤器已正确配置

---

## 4. Attempted Solutions & Results (已尝试的方案与结果)

### 4.1 数据清洗方案（部分成功）

#### 尝试 1：激进的数据清洗
**配置**：
```yaml
manipulate:
  - title:
      replace:
        regexp: '[\r\n\t\x00-\x1f\x7f-\x9f]+'  # 清理所有控制字符
        format: ' '
  - url:
      replace:
        regexp: '[\r\n\t\x00-\x1f\x7f-\x9f]+'
        format: ''
  - description:  # 尝试清理不存在的字段
      replace:
        regexp: '[\r\n\t\x00-\x1f\x7f-\x9f]+'
        format: ' '
  - link:
      replace:
        regexp: '[\r\n\t\x00-\x1f\x7f-\x9f]+'
        format: ''
```

**结果**：
- ❌ 导致新错误：`WARNING manipulate mt_free_seed Cannot replace, field 'link' is not present`
- ❌ 所有种子失败：`TransmissionError: Query failed with result "unrecognized info"`
- **原因**：过度清理破坏了种子的 info hash

#### 尝试 2：保守的数据清洗（当前方案）
**配置**：
```yaml
manipulate:
  - title:
      replace:
        regexp: '[\r\n]+'  # 只清理换行符和回车符
        format: ' '
  - url:
      replace:
        regexp: '[\r\n]+'
        format: ''
```

**结果**：
- ✅ 不再出现 "field is not present" 警告
- ⚠️ "unrecognized info" 错误仍然存在，但频率降低

### 4.2 速率限制方案（已实施）

#### 方案 1：domain_delay（已生效）
**配置**：
```yaml
domain_delay:
  m-team.cc: '5 seconds'
  rss.m-team.cc: '5 seconds'
  kp.m-team.cc: '5 seconds'
  halomt.com: '5 seconds'
  manfuz.co: '5 seconds'
```

**结果**：
- ✅ HTTP 503 错误已解决
- ⚠️ "unrecognized info" 错误仍然存在

#### 方案 2：delay 插件（已实施）
**配置**：
```yaml
delay: '3 seconds'  # 每下载一个种子文件后等待 3 秒
```

**结果**：
- ✅ 配置已生效（日志显示 "Delaying 20 new entries for 3 seconds"）
- ⚠️ "unrecognized info" 错误仍然存在

### 4.3 重试机制方案（当前配置）

#### 配置
```yaml
seen:
  local: yes
  fields:
    - url

retry_failed:
  retry_time: 30 minutes
  retry_time_multiplier: 1
  max_retries: 10

limit_new: 20
```

**预期行为**：
1. 优先下载新种子
2. 如果新种子 < 20 个，用失败种子填补
3. 失败种子在 30 分钟后重试

**实际结果**：
- ⚠️ 用户报告：重启后日志显示 "Task didn't produce any entries"
- ⚠️ RSS feed 中仍有大量未下载种子
- ❓ **疑问**：`retry_failed` 是否真的能让失败种子重新进入队列？

### 4.4 其他尝试过的方案

#### 尝试 1：降低 limit_new
- 从 20 降低到 5
- **结果**：用户拒绝，希望保持 20

#### 尝试 2：添加 skip_check 参数
```yaml
transmission:
  skip_check: yes
```
- **结果**：❌ 配置错误 "The key 'skip_check' is not valid here"

#### 尝试 3：添加 backlog 插件
```yaml
backlog: yes
```
- **结果**：❌ 配置错误 "Got 'True', expected: string"

---

## 5. Current Config Snippet (当前关键配置)

### FlexGet 配置文件：`PT_JP/config/flexget/config.yml`

```yaml
schedules:
  - tasks: ['mt_free_seed']
    interval:
      minutes: 30

tasks:
  mt_free_seed:
    rss:
      url: '{? mt_rss_url ?}'
      all_entries: no

    domain_delay:
      m-team.cc: '5 seconds'
      rss.m-team.cc: '5 seconds'
      kp.m-team.cc: '5 seconds'
      halomt.com: '5 seconds'
      manfuz.co: '5 seconds'

    manipulate:
      - title:
          replace:
            regexp: '[\r\n]+'
            format: ' '
      - url:
          replace:
            regexp: '[\r\n]+'
            format: ''

    content_size:
      min: 0.0001
      max: 12
      strict: no

    seen:
      local: yes
      fields:
        - url

    retry_failed:
      retry_time: 30 minutes
      retry_time_multiplier: 1
      max_retries: 10

    free_space:
      path: /downloads
      space: 25000

    accept_all: yes
    limit_new: 20
    delay: '3 seconds'

    transmission:
      host: transmission
      port: 9091
      username: '{? tr_user ?}'
      password: '{? tr_pass ?}'
      path: /downloads/complete
      add_paused: no
```

### Docker Compose 配置：`PT_JP/docker-compose.yml`

```yaml
services:
  transmission:
    image: lscr.io/linuxserver/transmission:4.0.6
    container_name: transmission_jp
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pgrep -x transmission-da > /dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s

  flexget:
    image: ghcr.io/flexget/flexget:3.11
    container_name: flexget_jp
    restart: unless-stopped
    command: daemon start --autoreload-config
    depends_on:
      transmission:
        condition: service_healthy
```

---

## 6. The Ask (下一阶段需求)

### 核心问题
**为什么 FlexGet 在运行一段时间后，会批量出现 "unrecognized info" 错误？**

### 具体需求

#### 6.1 诊断需求
1. **验证 `retry_failed` 是否正常工作**
   - 失败的种子是否真的在 30 分钟后重新进入队列？
   - 如何验证 `retry_failed` 的内部状态？

2. **分析种子文件下载过程**
   - 如何捕获 FlexGet 下载的原始种子文件（.torrent）？
   - 如何验证种子文件是否完整？

3. **排查 "unrecognized info" 的真正原因**
   - 是种子文件损坏？还是 Transmission 解析问题？
   - 如何复现这个问题？

#### 6.2 解决方案需求
1. **彻底解决 "unrecognized info" 错误**
   - 是否需要在 FlexGet 和 Transmission 之间添加种子文件验证？
   - 是否需要更换种子下载方式（如使用 `download` 插件）？

2. **确保重试机制正常工作**
   - 当前配置是否能实现"优先新种子，不足时用失败种子填补"？
   - 如果不能，应该如何修改配置？

3. **提高系统稳定性**
   - 如何避免批量失败？
   - 是否需要添加更多的错误处理机制？

#### 6.3 验证需求
请提供：
1. **诊断命令**：用于检查 FlexGet 内部状态的命令
2. **测试方案**：验证修复方案是否有效的测试步骤
3. **监控建议**：如何监控 FlexGet 的运行状态，及早发现问题

---

## 7. Additional Context (补充信息)

### 7.1 用户反馈
- 用户确认 RSS feed 中有大量符合条件的种子未被下载
- 用户希望保持 `limit_new: 20`，不希望降低到 5
- 用户可以接受个别种子失败，但不能接受批量失败

### 7.2 已知限制
- M-Team Tracker 有严格的速率限制
- 用户的服务器在日本，网络延迟可能较高
- 用户希望系统能 24/7 自动运行，无需人工干预

### 7.3 成功案例
- 初期（前 1.5-2 小时）系统运行正常，能成功下载种子
- `domain_delay` 成功解决了 HTTP 503 错误
- `delay` 插件已生效，日志显示正确的延迟行为

---

## 8. Files for Reference (参考文件)

### 关键文件路径
- **FlexGet 配置**: `PT_JP/config/flexget/config.yml`
- **Docker Compose**: `PT_JP/docker-compose.yml`
- **部署脚本**: `PT_JP/scripts/deploy.sh`
- **环境变量示例**: `PT_JP/.env.example`

### 日志位置
```bash
# FlexGet 日志
docker logs -f flexget_jp

# Transmission 日志
docker logs -f transmission_jp

# 容器状态
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

---

## 9. Timeline (问题时间线)

1. **初始部署**：系统正常运行，能成功下载种子
2. **1.5-2 小时后**：开始出现 "unrecognized info" 错误
3. **添加 domain_delay**：HTTP 503 错误解决
4. **添加 manipulate**：ValueError 部分解决，但 "unrecognized info" 仍存在
5. **添加 delay**：配置生效，但 "unrecognized info" 仍存在
6. **添加 retry_failed**：配置生效，但用户报告 "Task didn't produce any entries"

---

**报告结束**

请资深专家基于以上信息，提供：
1. 根本原因分析
2. 可行的解决方案
3. 验证和测试步骤

感谢！
