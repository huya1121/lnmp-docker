
# LNMP Docker 自动化部署脚本

一键部署 LNMP (Linux + Nginx + MySQL + PHP + Redis) 环境，支持 Let's Encrypt SSL 证书（单域名/通配符）、自动备份、断点续装等功能。

## 🚀 功能特点

- ✅ **一键部署** - 自动安装 Docker、配置服务、申请 SSL 证书
- ✅ **SSL 证书** - 支持单域名证书 (HTTP-01) 和通配符证书 (DNS-01)
- ✅ **多 DNS 服务商** - 支持 Cloudflare、阿里云、DNSPod
- ✅ **PHP 版本选择** - 支持 7.4, 8.0, 8.1, 8.2, 8.3, 8.4 或自定义版本
- ✅ **Redis 集成** - 内置 Redis 缓存服务
- ✅ **断点续装** - 中断后可从上次进度继续安装
- ✅ **自动备份** - 每日自动备份数据库和网站文件
- ✅ **证书自动续期** - 每日检查并自动续期 SSL 证书
- ✅ **命令行工具** - 丰富的管理命令 (status, restart, logs, backup 等)
- ✅ **独立子域名配置** - 每个子域名生成独立的 Nginx 配置文件
- ✅ **phpMyAdmin 可选** - 可选安装 phpMyAdmin 数据库管理工具

## 📋 系统要求

- **操作系统**: Debian 11/12, Ubuntu 20.04/22.04/24.04
- **权限**: Root 权限
- **域名**: 已解析到服务器 IP
- **端口**: 开放 80 和 443 端口
- **磁盘**: 建议至少 2GB 可用空间

## 🛠️ 服务组件

| 组件 | 版本 | 说明 |
|------|------|------|
| Nginx | Alpine | 高性能 Web 服务器 |
| PHP-FPM | 7.4 - 8.4 | PHP 处理器 (可选版本) |
| MariaDB | 10.11 | MySQL 兼容数据库 |
| Redis | Alpine | 内存缓存数据库 |
| Certbot | Latest | SSL 证书管理 |

## 📦 PHP 扩展

安装时会自动安装以下扩展：
- `pdo_mysql` / `mysqli` - MySQL 数据库连接
- `redis` - Redis 缓存支持

> 如需更多扩展，可通过 `docker compose exec php apk add` 和 `docker-php-ext-install` 自行安装。

## 📂 目录结构

部署完成后，项目目录结构如下：

```
./lnmp/data/
├── docker-compose.yml      # Docker 编排配置
├── .env                    # 环境变量配置
├── .credentials            # 数据库凭据 (请妥善保管!)
├── .install_progress       # 安装进度 (断点续装用)
├── README.md               # 项目文档
├── backup_task.sh          # 备份脚本
├── renew-cert.sh           # 证书续期脚本
├── backup.log              # 备份日志
├── backups/                # 备份文件目录
├── volumes/
│   ├── nginx/
│   │   └── conf.d/         # Nginx 配置文件 ⭐
│   ├── php/
│   │   └── www/            # 网站根目录 ⭐
│   ├── mysql/              # MySQL 数据
│   └── redis/              # Redis 数据
└── certbot/
    ├── conf/               # SSL 证书
    └── www/                # ACME 验证目录
```

## 🚀 快速开始

### 1. 下载脚本

```bash
wget https://raw.githubusercontent.com/your-repo/lnmp/deploy-lamp.sh
chmod +x deploy-lamp.sh
```

### 2. 运行部署

```bash
sudo ./deploy-lamp.sh
```

### 3. 按提示操作

脚本会引导您完成以下配置：
1. 输入主域名和子域名
2. 选择证书类型 (单域名/通配符)
3. 选择 PHP 版本
4. 是否安装 phpMyAdmin
5. 配置数据库密码 (自动生成或手动输入)

## 📋 命令行参数

```bash
./deploy-lamp.sh [选项]

安装和部署:
  (无参数)         完整安装向导
  --cert, -c       单独申请/重新申请 SSL 证书
  --renew          续期已有的 SSL 证书

服务管理:
  --status         查看服务运行状态
  --restart        重启所有服务
  --stop           停止所有服务
  --logs [服务]    查看日志 (nginx/php/mysql/redis)

备份和维护:
  --backup         立即执行备份
  --info           显示当前配置信息
  --health         健康检查

高级操作:
  --add-subdomain  添加新子域名
  --rebuild-php    重新构建 PHP 镜像 (可选择版本)
  --rebuild-mysql  重建 MySQL/MariaDB (可选择版本)
  --uninstall      卸载并清理所有数据
  --upgrade        升级脚本到最新版本
  --cleanup        清理未使用的 Docker 资源

其他:
  --help, -h       显示帮助信息
  --version, -v    显示版本号
```

## 📋 常用操作

### 查看服务状态

```bash
./deploy-lamp.sh --status
# 或
cd ./lnmp/data && docker compose ps
```

### 查看日志

```bash
./deploy-lamp.sh --logs           # 所有服务
./deploy-lamp.sh --logs nginx     # Nginx 日志
./deploy-lamp.sh --logs php       # PHP 日志
./deploy-lamp.sh --logs mysql     # MySQL 日志
```

### 重启服务

```bash
./deploy-lamp.sh --restart
```

### 健康检查

```bash
./deploy-lamp.sh --health
```

输出内容包括：
- 各服务运行状态
- 端口监听状态 (80/443)
- SSL 证书有效期
- 磁盘空间使用情况

### 数据库操作

```bash
cd ./lnmp/data

# 进入 MySQL 命令行
docker compose exec mysql mysql -u root -p

# 备份数据库
docker compose exec mysql mysqldump -u root -p"密码" --all-databases > backup.sql

# 恢复数据库
docker compose exec -T mysql mysql -u root -p"密码" < backup.sql
```

### 添加新子域名

```bash
./deploy-lamp.sh --add-subdomain
```

> 注意：如果使用单域名证书，添加子域名后需要重新申请证书 (`--cert`)

### SSL 证书续期

```bash
./deploy-lamp.sh --renew
```

## ⏰ 自动任务

| 任务 | 执行时间 | 说明 |
|------|----------|------|
| 数据备份 | 每天 02:00 | 备份数据库和网站文件，保留 7 天 |
| 证书续期 | 每天 03:00 | 检查并自动续期 SSL 证书 |

## 🔐 安全说明

1. **数据库密码** - 自动生成 24 位随机密码，保存在 `.credentials` 文件中
2. **凭据文件** - `.credentials` 文件权限设置为 600，仅 root 可读
3. **SSL 证书** - 使用 Let's Encrypt 免费证书，有效期 90 天，自动续期
4. **防火墙** - 自动配置 ufw 开放 80/443 端口

## 🔧 Docker 网络说明

服务通过 Docker 内部网络通信：

| 服务 | 容器名称 | 内部端口 | 外部端口 |
|------|----------|----------|----------|
| Nginx | lnmp_nginx | 80, 443 | 80, 443 |
| PHP-FPM | lnmp_php | 9000 | - (内部) |
| MySQL | lnmp_mysql | 3306 | - (内部) |
| Redis | lnmp_redis | 6379 | - (内部) |

> **注意**: PHP、MySQL、Redis 端口仅在 Docker 内部网络可用，不暴露给外部。  
> Nginx 通过 `fastcgi_pass php:9000` 连接 PHP-FPM。

## ❓ 故障排查

### 服务无法启动

```bash
# 查看所有服务状态
./deploy-lamp.sh --status

# 查看详细日志
./deploy-lamp.sh --logs

# 检查端口占用
netstat -tlnp | grep -E '80|443'
ss -tlnp | grep -E '80|443'
```

### PHP 容器检查

```bash
# 检查 PHP-FPM 进程
docker exec lnmp_php ps aux | grep php-fpm

# 查看已安装的 PHP 扩展
docker exec lnmp_php php -m

# PHP 版本信息
docker exec lnmp_php php -v
```

### 证书申请失败

1. 确认域名已正确解析到服务器 IP
2. 确认 80/443 端口可访问 (防火墙已开放)
3. 如使用 Cloudflare 代理，确认 API Token 正确
4. 查看详细错误信息：

```bash
# 查看 Certbot 日志
docker compose logs certbot

# 手动测试证书申请 (dry-run)
docker compose run --rm certbot certonly --dry-run -d example.com
```

### 数据库连接失败

```bash
# 检查 MySQL 容器状态
docker compose ps mysql

# 查看 MySQL 日志
docker compose logs mysql

# 测试连接
docker compose exec mysql mysql -u root -p -e "SELECT 1"
```

### 断点续装

如果安装中断，重新运行脚本会自动检测进度并询问是否继续：

```bash
./deploy-lamp.sh
# 检测到未完成的安装 (阶段: xxx)
# 是否继续上次安装? [Y/n]:
```

如需重新开始，选择 `n` 或手动删除进度文件：

```bash
rm ./lnmp/data/.install_progress
```

## 📝 更新日志

### v2.2.0 (当前版本)
- 🔧 修复备份脚本中 `which` 命令可能不存在的问题，改用 POSIX 兼容的 `command -v`
- 🔧 改进 Nginx 启动验证：添加最多 30 秒的等待循环，替代固定 5 秒延时
- 🔧 修复 Docker 网络检测竞态条件：增加等待时间和多种网络名称获取方式
- 🔧 增强密码生成备选方案：使用多种熵源（RANDOM、时间戳、PID、主机名）生成更安全的随机密码
- 🔧 修复 `show_help()` 函数中的缩进不一致问题
- 🆕 新增高级操作命令：`--rebuild-php`、`--rebuild-mysql`、`--upgrade`、`--cleanup`
- 🔧 改进跨平台兼容性（macOS/Linux）

### v2.0.0
- 🆕 支持通配符 SSL 证书 (DNS-01 验证)
- 🆕 支持 Cloudflare、阿里云、DNSPod DNS 验证
- 🆕 PHP 版本选择 (7.4 - 8.4)
- 🆕 Redis 缓存服务集成
- 🆕 断点续装功能
- 🆕 独立子域名 Nginx 配置文件
- 🆕 phpMyAdmin 可选安装
- 🆕 命令行管理工具 (--status, --restart, --logs 等)
- 🆕 健康检查功能 (--health)
- 🆕 添加子域名功能 (--add-subdomain)
- 🆕 美化界面 (ASCII Banner, 进度条, 彩色图标)
- 🔧 改进备份脚本，支持环境变量
- 🔧 改进错误处理，兼容 set -e

### v1.0.0
- 初始版本
- 支持一键部署 LAMP 环境
- 支持 Let's Encrypt SSL 证书

## 📄 许可证

MIT License

---

**提示**: 部署完成后，凭据信息保存在 `./lnmp/data/.credentials` 文件中。
