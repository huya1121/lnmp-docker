
# LNMP Docker 自动化部署脚本

一键部署 LNMP (Linux + Nginx + MySQL + PHP + Redis) 环境，支持 Let's Encrypt SSL 证书（单域名/通配符）、自动备份、断点续装等功能。
(chown -R 82:82 volumes/php/www Alpine 版官方 PHP 镜像里的 www-data 用户 UID/GID 是 82，不是 Debian 系里常见的 33，这个要修改不然很多程序无法保存配置。)

## 🚀 功能特点

- ✅ **一键部署** - 自动安装 Docker、配置服务、申请 SSL 证书
- ✅ **SSL 证书** - 支持单域名证书 (HTTP-01) 和通配符证书 (DNS-01)
- ✅ **多 DNS 服务商** - 支持 Cloudflare、阿里云、DNSPod
- ✅ **PHP 版本选择** - 支持 7.4, 8.0, 8.1, 8.2, 8.3, 8.4 或自定义版本
- ✅ **Redis 集成** - 内置 Redis 缓存服务
- ✅ **反向代理** - 支持反向代理到宿主机服务 (Node.js、Python、Go 等)
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
| Nginx | 可选 (见下方) | 高性能 Web 服务器 |
| PHP-FPM | 7.4 - 8.4 | PHP 处理器 (可选版本) |
| MariaDB | 10.11 | MySQL 兼容数据库 |
| Redis | Alpine | 内存缓存数据库 |
| Certbot | Latest | SSL 证书管理 |

### Nginx 版本选择

安装时可以选择三种 Nginx 类型：

| 类型 | 镜像 | GeoIP2 | 说明 |
|------|------|--------|------|
| **官方 Nginx + GeoIP2** (推荐) | 自动构建 | ✅ 支持 | 从 nginx:alpine 自动编译 GeoIP2 模块 |
| **LinuxServer Nginx** | linuxserver/nginx | ✅ 支持 | 预装 GeoIP2，开箱即用 |
| **官方 Nginx 标准版** | nginx:alpine | ❌ 无 | 最小镜像，无 GeoIP2 支持 |

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
│   │   └── config/         # linuxserver/nginx 配置目录 ⭐
│   │       └── nginx/
│   │           ├── nginx.conf       # 主配置 (含 GeoIP2 模块)
│   │           └── site-confs/      # 虚拟主机配置文件
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
  --add-proxy      添加反向代理到宿主机服务
  --rebuild-nginx  重新构建 Nginx 镜像 (可切换类型)
  --rebuild-php    重新构建 PHP 镜像 (可选择版本)
  --rebuild-mysql  重建 MySQL/MariaDB (可选择版本)
  --reconfig       从现有 .env 重新生成配置并重建 (应用时区/内存/续期/备份等修复，不动数据)
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

> 以下命令均在项目目录 `./lnmp` 下执行（`docker-compose.yml` 所在目录），root 密码见 `./lnmp/.credentials`。
> MariaDB 数据库为 `mysql` 服务，容器名 `lnmp_mysql`。

```bash
cd ./lnmp
```

#### 进入数据库命令行

```bash
docker compose exec mysql mysql -u root -p
# 直接执行单条 SQL
docker compose exec mysql mysql -u root -p -e "SHOW DATABASES;"
```

#### 创建数据库 / 用户并授权

```bash
# 创建数据库 (utf8mb4)
docker compose exec mysql mysql -u root -p -e \
  "CREATE DATABASE mydb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# 创建用户并授权 (% 表示允许容器网络内任意主机连接)
docker compose exec mysql mysql -u root -p -e \
  "CREATE USER 'appuser'@'%' IDENTIFIED BY 'StrongPassword';
   GRANT ALL PRIVILEGES ON mydb.* TO 'appuser'@'%';
   FLUSH PRIVILEGES;"
```

#### 备份数据库

> 自动备份已默认开启（见下方「自动任务」），此处为手动操作。
> MariaDB 10.5+ 推荐用 `mariadb-dump`（`mysqldump` 为其别名，通常也可用）。

```bash
# 备份单个数据库
docker compose exec mysql mariadb-dump -u root -p"密码" mydb > mydb_backup.sql

# 备份全部数据库
docker compose exec mysql mariadb-dump -u root -p"密码" --all-databases > all_backup.sql

# 备份并直接压缩 (推荐大库)
docker compose exec mysql mariadb-dump -u root -p"密码" mydb | gzip > mydb_backup.sql.gz

# 使用脚本一键备份 (数据库 + 网站文件，输出到 ./lnmp/backups/)
./deploy-lamp.sh --backup
```

#### 恢复数据库

```bash
# 从 .sql 文件恢复到指定数据库 (需先存在该库)
docker compose exec -T mysql mysql -u root -p"密码" mydb < mydb_backup.sql

# 恢复全部数据库
docker compose exec -T mysql mysql -u root -p"密码" < all_backup.sql

# 从 .gz 压缩包恢复
gunzip < mydb_backup.sql.gz | docker compose exec -T mysql mysql -u root -p"密码" mydb

# 恢复自动备份 (backups 目录下按时间命名的 db_YYYYmmdd_HHMMSS.sql)
docker compose exec -T mysql mysql -u root -p"密码" < ./backups/db_20260812_020000.sql
```

> 注意：恢复时使用 `-T`（禁用伪 TTY），否则重定向输入会失败。

#### 查看数据库列表与占用大小

```bash
# 数据库列表
docker compose exec mysql mysql -u root -p -e "SHOW DATABASES;"

# 各数据库占用大小 (MB)
docker compose exec mysql mysql -u root -p -e \
  "SELECT table_schema AS '数据库',
          ROUND(SUM(data_length + index_length)/1024/1024, 2) AS '大小(MB)'
   FROM information_schema.tables GROUP BY table_schema;"
```

#### 导入 / 导出单张表

```bash
# 导出单表
docker compose exec mysql mariadb-dump -u root -p"密码" mydb mytable > mytable.sql

# 导入单表
docker compose exec -T mysql mysql -u root -p"密码" mydb < mytable.sql
```

### Redis 操作

```bash
cd ./lnmp

# 进入 Redis 命令行 (密码见 .credentials)
docker compose exec redis redis-cli -a "Redis密码"

# 查看所有 key / 内存占用 / 清空当前库
docker compose exec redis redis-cli -a "Redis密码" KEYS '*'
docker compose exec redis redis-cli -a "Redis密码" INFO memory
docker compose exec redis redis-cli -a "Redis密码" FLUSHDB
```

### 重新应用配置到现有部署 (`--reconfig`)

当脚本更新了配置生成逻辑（如时区、PHP 内存、证书续期、备份保留天数等修复），已在运行的部署不会自动获得这些改动。使用 `--reconfig` 从现有 `.env` 重新生成全部配置并重建：

```bash
./deploy-lamp.sh --reconfig
```

- **会重新生成**：PHP Dockerfile / `www.conf` / `custom.ini`、MySQL `custom.cnf`、`docker-compose.yml` + `.env`、Nginx 主配置、`backup_task.sh`、`renew-cert.sh`
- **会重建镜像**：PHP 与官方 Nginx 镜像（时区烤在镜像层内，故需重建），随后 `docker compose up -d` 重建容器
- **不会改动**：数据库数据、SSL 证书、已添加的子域名与站点配置、网站文件
- 执行前会展示检测到的部署拓扑并要求确认

> 首次重建镜像可能耗时几分钟。redis / 标准 Nginx / certbot 容器跟随宿主机时区，建议宿主机执行 `timedatectl set-timezone Asia/Shanghai`。

#### `--reconfig` 会导致数据丢失吗？

**不会。** `--reconfig` 不执行 `docker compose down -v`、不删除任何数据卷、不改动数据目录。数据库数据、网站文件、SSL 证书、Redis 数据都存放在**绑定挂载的卷**里（`./volumes/mysql/data`、`./volumes/php/www`、`./certbot/conf`、`./volumes/redis`），重建容器时会原样重新挂回。它也不调用初始化站点 / 申请证书 / 写首页的逻辑，因此证书与已加子域名配置都保留。

不过在**旧部署**上执行前，请留意以下几点（多为潜在坑，并非必然丢数据）：

1. **确认 MariaDB 版本一致（最重要）**：重生成的 `docker-compose.yml` 会按 `.env` 里的 `MARIADB_VERSION` 选镜像。若旧 `.env` 缺该值，会回落到脚本默认版本——万一与实际运行版本不同，`up -d` 会用新版本容器挂旧数据，跨大版本可能需要 `mysql_upgrade`。执行前请对比：
   ```bash
   grep -E 'MARIADB_VERSION|PHP_VERSION' .env
   docker compose exec mysql mariadb --version
   ```
2. **卷路径需一致**：若旧部署使用了不同的卷布局（命名卷或其他路径），数据不会被删除，但新配置可能挂到空目录、看起来"像丢了"。使用本 `volumes/` 结构的部署无此问题。
3. **行为变化（非丢数据）**：MySQL 新增 `default-time-zone = '+08:00'`，已存 `TIMESTAMP` 值不变，但 `NOW()` 与时间显示按东八区；Redis 新增 `--maxmemory-policy allkeys-lru`，若把 Redis 当持久存储用（非纯缓存），内存满时会淘汰 key。
4. **短暂停机**：重建容器期间服务会中断几十秒到几分钟。
5. **自定义特殊字符密码**：脚本自动生成的密码为纯字母数字，安全；若手填过含 `$`、反引号、引号的密码，`.env` 经 source→重写可能损坏导致登录失败（连不上，非丢数据）。

**稳妥流程：**

```bash
cd ./lnmp
./deploy-lamp.sh --backup                    # 1. 先备份 (数据库+网站 → backups/)
grep -E 'MARIADB_VERSION|PHP_VERSION' .env   # 2. 确认版本值存在
docker compose exec mysql mariadb --version  #    对比实际运行版本
./deploy-lamp.sh --reconfig                  # 3. 执行 (会显示拓扑让你确认)
./deploy-lamp.sh --health                    # 4. 检查各服务
```

### 添加新子域名

```bash
./deploy-lamp.sh --add-subdomain
```

> 注意：如果使用单域名证书，添加子域名后需要重新申请证书 (`--cert`)

### 反向代理到宿主机服务

当您在宿主机上运行 Node.js、Python、Go 等服务时，可以使用 Nginx 反向代理将请求转发到这些服务。

```bash
./deploy-lamp.sh --add-proxy
```

脚本会引导您完成配置：
1. 输入子域名（如 `api` 将创建 `api.example.com`）
2. 输入宿主机服务端口（如 `3000`）
3. 选择代理协议（HTTP/HTTPS）

#### 工作原理

Docker 容器默认无法直接访问宿主机的 `127.0.0.1`。脚本通过以下方式解决：

1. 在 docker-compose.yml 中配置 `extra_hosts`:
   ```yaml
   extra_hosts:
     - "host.docker.internal:host-gateway"
   ```

2. 生成的 Nginx 配置使用 `host.docker.internal` 访问宿主机:
   ```nginx
   upstream api_backend {
       server host.docker.internal:3000;
   }
   ```

#### 注意事项

⚠️ **宿主机服务必须监听在 `0.0.0.0` 而非 `127.0.0.1`**

```bash
# ❌ 错误 - 容器无法访问
node app.js --host 127.0.0.1 --port 3000

# ✅ 正确 - 容器可以访问
node app.js --host 0.0.0.0 --port 3000
```

常见框架配置示例：

| 框架 | 正确配置 |
|------|----------|
| Node.js Express | `app.listen(3000, '0.0.0.0')` |
| Python Flask | `flask run --host=0.0.0.0` |
| Python FastAPI | `uvicorn main:app --host 0.0.0.0` |
| Go Gin | `r.Run("0.0.0.0:3000")` |

### 一键卸载

```bash
./deploy-lamp.sh --uninstall
```

**⚠️ 警告**: 此操作将彻底删除所有数据，包括：
- 所有 Docker 容器和镜像
- 数据库数据 (MySQL/MariaDB)
- 网站文件
- SSL 证书
- 配置文件
- 备份文件

**卸载流程**：
1. 运行 `./deploy-lamp.sh --uninstall`
2. 输入 `yes` 确认卸载（必须输入完整的 "yes"，而非 "y"）
3. 脚本会自动：
   - 停止并删除所有 Docker 容器
   - 删除 Docker 镜像和网络
   - 移除定时任务 (crontab)
   - 备份凭据文件到脚本所在目录
   - 删除项目目录

**卸载前建议**：
```bash
# 1. 先备份重要数据
./deploy-lamp.sh --backup

# 2. 导出数据库
cd ./lnmp/data
docker compose exec mysql mysqldump -u root -p"密码" --all-databases > /tmp/db_backup.sql

# 3. 复制网站文件
cp -r ./volumes/php/www /tmp/www_backup

# 4. 保存凭据文件
cp .credentials ~/credentials_backup.txt

# 5. 执行卸载
./deploy-lamp.sh --uninstall
```

### SSL 证书续期

```bash
./deploy-lamp.sh --renew
```

## ⏰ 自动任务

| 任务 | 执行时间 | 说明 |
|------|----------|------|
| 数据备份 | 每天 02:00 | 备份数据库和网站文件，保留 3 天 |
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

### v2.6.0 (当前版本)
- 🆕 **一键重新配置**: 新增 `--reconfig` 命令，从现有 `.env` 重新生成全部配置并重建，把时区/内存/续期/备份等修复应用到已运行的部署，不影响数据、证书、子域名配置
- 🆕 **配置持久化**: `NGINX_TYPE` / `INSTALL_PHPMYADMIN` / `CERT_TYPE` / `DNS_PROVIDER` / 子域名列表迁移进 `.env`（此前装完即丢）；`--reconfig` 对旧部署自动探测补齐
- 🕐 **全容器中国时区**: PHP / 官方 Nginx 镜像内置 tzdata 并设为 `Asia/Shanghai`，各服务补充 `TZ` 环境变量，redis / 标准 Nginx / certbot 挂载宿主机时区文件；MySQL 设 `default-time-zone = '+08:00'`
- 🧠 **PHP 内存保护**: `pm.max_children` 改为按可用内存动态计算，避免进程数 × `memory_limit` 撑爆内存；新增 `request_terminate_timeout` 回收卡死请求
- 🐛 修复证书自动续期：certbot 常驻 entrypoint 导致 `renew` 从未真正执行，改用 `--entrypoint certbot` 覆盖
- 🆕 **反向代理支持**: 新增 `--add-proxy` 命令，支持反向代理到宿主机服务
- 🆕 **Nginx 重建命令**: 新增 `--rebuild-nginx` 命令，支持重新构建或切换 Nginx 类型
- 🆕 **host.docker.internal**: 自动配置 `extra_hosts`，容器可通过 `host.docker.internal` 访问宿主机
- 🔧 支持代理到 Node.js、Python、Go 等宿主机上运行的服务
- 🔧 自动生成包含 WebSocket 支持的 Nginx 反向代理配置

### v2.5.0
- 🆕 **多 Nginx 类型支持**: 安装时可选择三种 Nginx 配置
  - 官方 Nginx + GeoIP2 (推荐): 自动编译 ngx_http_geoip2_module
  - LinuxServer Nginx: 预装 GeoIP2，开箱即用
  - 官方 Nginx 标准版: 最小镜像，无 GeoIP2
- 🆕 **GeoIP2 自动编译**: 官方 nginx 模式使用多阶段 Docker 构建
- 🔧 根据 Nginx 类型自动适配目录结构和配置

### v2.4.0
- 🆕 **Nginx 镜像更换**: 从 `nginx:alpine` 切换到 `linuxserver/nginx`
- 🆕 **GeoIP2 支持**: linuxserver/nginx 预装 GeoIP2 模块
- 🔧 更新目录结构适配 linuxserver/nginx

### v2.3.0
- 🔒 **安全修复**: Redis 添加密码认证，修复安全警告 "Redis 没有要求身份验证且不受网络限制保护"
- 🔧 Redis 密码自动生成并保存至 `.credentials` 文件
- 🔧 PHP 环境变量中添加 `REDIS_PASSWORD`，支持应用程序安全连接 Redis
- 🔧 更新示例 `index.php`，演示带认证的 Redis 连接

### v2.2.0
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
