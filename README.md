# Ethereum RPC Service

基于 **Ubuntu 24.04 LTS x64** 的高可用以太坊 JSON-RPC 服务部署方案。

## 架构概览

```
                    ┌──────────────┐
    Client ────────►│    Nginx     │ 限流 / 方法过滤 / 缓存
                    │  (Port 80)   │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌────────────┐
        │   Geth   │ │   Geth   │ │HealthCheck │
        │  HTTP    │ │   WS     │ │  Service   │
        │ :8545    │ │  :8546   │ │   :8080    │
        └────┬─────┘ └──────────┘ └────────────┘
             │ JWT Auth
        ┌────▼──────┐
        │Lighthouse │ Consensus Client
        │  :5052    │
        └───────────┘

        ┌───────────┐     ┌─────────┐
        │Prometheus │────►│ Grafana │ 监控面板
        │  :9090    │     │  :3000  │
        └───────────┘     └─────────┘
```

## 组件说明

| 组件 | 说明 | 端口 |
|------|------|------|
| **Geth** | 以太坊执行层客户端 (EL) | 8545 (HTTP), 8546 (WS), 30303 (P2P) |
| **Lighthouse** | 以太坊共识层客户端 (CL) | 5052 (API), 9000 (P2P) |
| **Nginx** | 反向代理、限流、方法过滤、响应缓存 | 80 (HTTP) |
| **Health Check** | 节点健康检查 API + Prometheus 指标 | 8080 |
| **Prometheus** | 指标采集与存储 | 9090 |
| **Grafana** | 可视化监控面板 | 3000 |

## 硬件要求

| 配置项 | 最低要求 | 推荐配置 |
|--------|---------|---------|
| CPU | 4 核 | 8+ 核 |
| 内存 | 16 GB | 32 GB |
| 存储 | 2 TB NVMe SSD | 4 TB NVMe SSD |
| 网络 | 25 Mbps | 100+ Mbps |
| 系统 | Ubuntu 24.04 LTS x64 | Ubuntu 24.04 LTS x64 |

> **重要**: Geth 主网全量数据约 1.2-1.5 TB 且持续增长。务必使用 NVMe SSD，SATA SSD 性能不足。

## 快速部署

### 1. 克隆项目

```bash
git clone <your-repo-url> /opt/eth-rpc
cd /opt/eth-rpc
```

### 2. 运行初始化脚本

```bash
sudo bash scripts/setup.sh
```

该脚本将自动完成：
- 系统更新与依赖安装
- Docker 安装与配置
- 数据目录创建 (`/data/ethereum/`)
- JWT 认证密钥生成
- 系统内核参数调优
- UFW 防火墙配置
- NTP 时间同步
- Systemd 服务注册

### 3. 编辑配置

```bash
nano .env
```

关键配置项：

```bash
# 选择网络 (mainnet / sepolia / holesky)
ETH_NETWORK=mainnet

# 数据存储路径 (确保磁盘空间充足)
GETH_DATA_DIR=/data/ethereum/geth
LIGHTHOUSE_DATA_DIR=/data/ethereum/lighthouse

# Geth 内存缓存 (建议设为总内存的 25%，单位 MB)
GETH_CACHE=8192

# Lighthouse 检查点同步 URL (加速首次同步)
LIGHTHOUSE_CHECKPOINT_SYNC_URL=https://mainnet.checkpoint.sigp.io

# Grafana 管理员密码 (务必修改)
GRAFANA_ADMIN_PASSWORD=your_strong_password_here
```

### 4. 启动服务

```bash
# 方式一：使用 docker compose
docker compose up -d

# 方式二：使用 systemd (推荐生产环境)
sudo systemctl start eth-rpc
```

### 5. 验证部署

```bash
# 查看容器状态
docker compose ps

# 查看 Geth 同步日志
docker compose logs -f geth

# 测试 RPC 端点
curl -s -X POST http://localhost \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq

# 检查节点健康状态
curl -s http://localhost:8080/health | jq

# 运行完整诊断
bash scripts/health-check.sh
```

## 同步时间预估

| 网络 | Geth (snap sync) | Lighthouse (checkpoint sync) |
|------|------------------|------------------------------|
| Mainnet | 6-12 小时 | 5-15 分钟 |
| Sepolia | 1-3 小时 | 5-10 分钟 |
| Holesky | 2-5 小时 | 5-10 分钟 |

> Lighthouse 启用了 checkpoint sync，可在数分钟内完成共识层同步。

## API 使用

### HTTP JSON-RPC

```bash
# 获取最新区块号
curl -X POST http://<server-ip> \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 获取账户余额
curl -X POST http://<server-ip> \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x...","latest"],"id":1}'

# 获取链 ID
curl -X POST http://<server-ip> \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

### WebSocket

```bash
# 使用 wscat 连接
wscat -c ws://<server-ip>/ws

# 订阅新区块头
> {"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
```

### 可用的 RPC 方法

通过 Nginx 暴露以下命名空间：

| 命名空间 | HTTP | WebSocket | 说明 |
|----------|------|-----------|------|
| `eth_*` | ✅ | ✅ | 核心以太坊方法 |
| `net_*` | ✅ | ✅ | 网络状态 |
| `web3_*` | ✅ | ✅ | 工具方法 |
| `txpool_*` | ❌ | ❌ | 已屏蔽 (安全) |
| `debug_*` | ❌ | ❌ | 已屏蔽 (安全) |
| `admin_*` | ❌ | ❌ | 已屏蔽 (安全) |
| `personal_*` | ❌ | ❌ | 已屏蔽 (安全) |

## 安全特性

### Nginx 层

- **限流**: HTTP RPC 30 req/s，WebSocket 10 req/s（每 IP）
- **方法过滤**: 自动屏蔽 admin/debug/personal/miner 等危险方法
- **响应缓存**: 对不可变数据（已确认的区块、交易）启用缓存
- **安全头**: X-Content-Type-Options, X-Frame-Options

### 网络层

- UFW 防火墙仅开放必要端口
- 执行层/共识层之间使用 JWT 认证
- 监控端口不对外暴露（需手动放行）

### 系统层

- Docker 容器隔离
- 内部 Docker 网络，RPC 端口不直接暴露
- 系统内核参数调优

## 监控

### Grafana 面板

访问 `http://<server-ip>:3000`，默认用户名 `admin`，密码在 `.env` 中设置。

预配置面板包含：
- 同步状态 (已同步 / 同步中)
- 最新区块号
- 对等节点数
- 共识层同步距离
- RPC 延迟 (p50/p95/p99)
- 健康检查结果
- Geth 内存使用

### Prometheus 指标

`http://<server-ip>:9090` — 采集以下目标：
- Geth 内置指标 (`:6060/debug/metrics/prometheus`)
- Lighthouse 内置指标 (`:5054/metrics`)
- 健康检查服务自定义指标 (`:8080/metrics`)

### 健康检查端点

| 端点 | 说明 |
|------|------|
| `GET /health` | 综合健康状态 (200=健康, 503=异常) |
| `GET /health/live` | 存活探针 |
| `GET /health/ready` | 就绪探针 |
| `GET /metrics` | Prometheus 格式指标 |

## 运维操作

### 常用命令

```bash
# 查看所有容器日志
docker compose logs -f

# 仅查看 Geth 日志
docker compose logs -f geth

# 重启单个服务
docker compose restart geth

# 停止所有服务 (优雅关闭，等待 3 分钟)
docker compose down --timeout 180

# 更新客户端版本
docker compose pull
docker compose up -d

# 运行健康诊断
bash scripts/health-check.sh
```

### 备份

```bash
# 手动备份
sudo bash scripts/backup.sh

# 设置定时备份 (每天凌晨 3 点)
sudo crontab -e
# 添加: 0 3 * * * /opt/eth-rpc/scripts/backup.sh >> /var/log/eth-backup.log 2>&1
```

备份内容包括：
- 项目配置文件 (.env, docker-compose.yml, nginx 配置等)
- Geth nodekey（节点身份密钥）
- Grafana 数据库

> **注意**: 不备份链数据本身（太大且可重新同步），仅备份配置和关键密钥。

### 客户端升级

```bash
# 1. 拉取最新镜像
docker compose pull

# 2. 滚动重启
docker compose up -d

# 3. 确认服务正常
bash scripts/health-check.sh
```

### 磁盘空间管理

```bash
# 查看数据占用
du -sh /data/ethereum/geth
du -sh /data/ethereum/lighthouse

# 清理 Docker 缓存
docker system prune -f

# Geth 在线修剪 (state.scheme=path 模式下自动执行)
```

## 故障排查

### Geth 同步缓慢

```bash
# 检查对等节点数
curl -s -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' | jq

# 对等节点 < 5: 检查防火墙是否放行 30303 端口
# 建议增大 GETH_CACHE 和 GETH_MAX_PEERS
```

### Lighthouse 无法连接 Geth

```bash
# 确认 JWT 密钥一致
docker compose exec geth cat /jwt/jwt.hex
docker compose exec lighthouse cat /jwt/jwt.hex

# 检查 Auth RPC 端口
docker compose logs lighthouse | grep "execution"
```

### Nginx 返回 429 (Too Many Requests)

调整 `.env` 中的限流参数，或修改 `nginx/conf.d/rpc.conf` 中的 `limit_req` 配置：

```nginx
limit_req zone=rpc_limit burst=100 nodelay;
```

### 磁盘空间不足

```bash
# 查看磁盘使用
df -h /data

# 清理 Docker 无用数据
docker system prune -af --volumes

# 考虑迁移到更大磁盘或启用 LVM 扩容
```

### 容器反复重启

```bash
# 查看具体错误
docker compose logs --tail=100 <service_name>

# 检查系统资源
htop
iotop -o
```

## 目录结构

```
.
├── .env.example                     # 环境变量模板
├── .gitignore
├── .dockerignore
├── docker-compose.yml               # 容器编排
├── README.md                        # 本文档
├── nginx/
│   ├── nginx.conf                   # Nginx 主配置
│   └── conf.d/
│       └── rpc.conf                 # RPC 代理 + 限流 + 缓存
├── healthcheck/
│   ├── Dockerfile                   # 健康检查服务镜像
│   ├── requirements.txt
│   └── app.py                       # FastAPI 健康检查 + 指标
├── monitoring/
│   ├── prometheus/
│   │   └── prometheus.yml           # Prometheus 采集配置
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── datasource.yml   # Grafana 数据源
│           └── dashboards/
│               ├── dashboard.yml    # Dashboard 加载配置
│               └── ethereum-rpc.json # 预配置面板
├── scripts/
│   ├── setup.sh                     # 一键初始化脚本
│   ├── backup.sh                    # 备份脚本
│   └── health-check.sh             # CLI 健康诊断
├── systemd/
│   └── eth-rpc.service             # Systemd 服务单元
└── jwt/                             # JWT 密钥目录 (git ignored)
```

## 生产环境建议

1. **HTTPS**: 使用 Let's Encrypt 或自有证书替换自签名证书
2. **IP 白名单**: 在 Nginx 或 UFW 层限制 RPC 访问来源
3. **API Key 认证**: 添加 Nginx 层的 API Key 验证
4. **多节点冗余**: 部署 2+ 节点，Nginx upstream 配置负载均衡
5. **独立监控**: 将 Prometheus/Grafana 部署到独立服务器
6. **告警**: 在 Grafana 中配置 Alerting（Telegram/Slack/Email）
7. **日志聚合**: 接入 Loki 或 ELK 进行集中日志管理
8. **定期升级**: 关注 Geth/Lighthouse 安全更新公告
