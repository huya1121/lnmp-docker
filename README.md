# LNMP Docker 一键部署脚本

> **L**inux + **N**ginx + **M**ySQL/MariaDB + **P**HP + **R**edis，基于 Docker 的生产级自动化部署脚本。
>
> 版本 **v2.12.0** · 单文件 `deploy.sh` · 交互式向导 + 全套运维子命令

一条命令把一台干净的 Linux 服务器变成带 **自动 HTTPS、WAF 防护、fail2ban 封禁、定时备份** 的 LNMP 环境。所有服务跑在 Docker 容器里，互不污染宿主机。

---

## ✨ 核心特性

- **一键安装向导** — 交互式选择 PHP / 数据库 / Nginx 版本、域名、证书类型，全程自动。
- **自动 HTTPS + HTTP/3** — 集成 certbot，支持单域名证书与 DNS 通配符证书（Cloudflare / 阿里云 / DNSPod），并自动续期；所有 HTTPS 站点默认开启 HTTP/3（QUIC）。
- **三种 Nginx 方案**
  - `official` — 官方 nginx:alpine + 自动编译 GeoIP2 动态模块（跟随最新稳定版）
  - `linuxserver` — linuxserver/nginx，预装 GeoIP2，开箱即用
  - `standard` — 官方 nginx:alpine 标准版，无 GeoIP2，构建最快
- **安全防护（WAF + fail2ban）**
  - 恶意 UA / 扫描路径直接 `444` 断连，省带宽
  - 请求限速 / 并发限制，超限返回 `429`
  - fail2ban 捕获 429 累计自动封禁 IP
  - 自带**网页解封面板**（Basic Auth 保护，PHP 只写队列、root 桥接脚本执行，权限隔离）
- **定时备份** — 自动备份数据库与网站，按天数滚动保留（默认 3 天）；可选用 rclone 推送到云盘（OneDrive / Google Drive / S3 等）。
- **多站点** — 随时添加 / 删除子域名，一键配置反向代理到宿主机服务。
- **安全运维** — 重建镜像、重置数据库密码、重新生成配置均**不动数据卷**。
- **断点续装** — 安装过程记录进度，中断后重跑自动从上次阶段继续。

---

## 🧩 技术栈默认值

| 组件 | 默认 | 可选 |
|------|------|------|
| PHP | 8.2 | 向导中 1–7 项或自定义版本 |
| 数据库 | MariaDB 10.11 | 其它 MariaDB 版本 / `mysql:8.0` 等 |
| Nginx | official（GeoIP2） | linuxserver / standard |
| Redis | redis:alpine | — |
| HTTP 协议 | HTTP/1.1 + HTTP/2 + HTTP/3（QUIC，默认开启） | — |
| PHP 扩展 | mysqli, pdo_mysql, curl, zip, mbstring, xml, gd, intl, opcache, bcmath, exif, redis | — |

> **HTTP/3 需放行 UDP 443**：QUIC 走 UDP，宿主机防火墙 / 云安全组要放行 **UDP 443**（除已有的 TCP 80/443 外），否则浏览器会静默回退到 HTTP/2，看起来"没生效"。
>
> **套 Cloudflare 橙云的域名**：浏览器到 CF 之间的 HTTP/3 由 Cloudflare 负责，而 **CF 回源不走 HTTP/3**（只用 HTTP/1.1/2）。所以源站开 HTTP/3 对经 CF 代理的访客基本无感；真正用到源站 HTTP/3 的是直连 / 灰云 / 不过 CF 的域名。

---

## 🚀 快速开始

> 要求：一台可联网的 Linux 服务器（脚本会自动安装 Docker 与 compose 插件），域名已解析到本机 IP，具备 root 权限。

```bash
# 1. 下载脚本
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/huya1121/lnmp-docker/main/lnmp.sh
chmod +x deploy.sh

# 2. 运行完整安装向导（无参数即进入向导）
sudo ./deploy.sh
```

向导会依次引导你选择 PHP / 数据库 / Nginx 版本、填写域名、选择证书类型（单域名或 DNS 通配符）、设置数据库密码等。完成后所有服务自动构建并启动。

安装完成后，项目文件位于脚本同目录下的 `lnmp/`，凭据保存在 `lnmp/.credentials`，详细文档自动生成到 `lnmp/README.md`。

---

## 📁 目录结构

安装完成后生成于 `./lnmp/`：

```
lnmp/
├── docker-compose.yml       # 运行时由脚本自动生成（请勿手改，用 --reconfig 重生成）
├── .env                     # 版本/密码等变量
├── .credentials             # 各服务凭据（妥善保管）
├── docker/                  # PHP / Nginx 的 Dockerfile 与构建上下文
├── volumes/
│   ├── nginx/               # Nginx 配置、WAF 守卫片段
│   ├── php/www/             # 网站根目录（按域名分子目录）
│   ├── mysql/{data,conf.d}/ # 数据库数据与配置
│   └── redis/               # Redis 数据
├── fail2ban-panel/          # 网页解封面板
├── certbot/                 # SSL 证书
└── backups/                 # 定时备份输出
```

> 注意：`docker-compose.yml` 不是手写文件，而是 `deploy.sh` 运行时根据你的选择生成的。要改配置，改向导选项或 `.env` 后运行 `./deploy.sh --reconfig`，而非直接编辑。

---

## ⌨️ 常用命令

```bash
# ---- 安装 / 证书 ----
./deploy.sh                      # 完整安装向导
./deploy.sh --cert               # 单独申请 / 重新申请 SSL 证书
./deploy.sh --renew              # 续期已有证书

# ---- 服务管理 ----
./deploy.sh --status             # 查看服务状态
./deploy.sh --restart            # 重启所有服务
./deploy.sh --stop               # 停止所有服务
./deploy.sh --logs [服务]        # 查看日志（nginx/php/mysql/redis）
./deploy.sh --health             # 健康检查
./deploy.sh --info               # 显示当前配置信息

# ---- 备份 ----
./deploy.sh --backup             # 立即备份
./deploy.sh --setup-cloud-backup # 配置备份到云盘（rclone）

# ---- 域名 / 代理 ----
./deploy.sh --add-subdomain      # 添加子域名
./deploy.sh --del-subdomain api  # 删除子域名（可带名称）
./deploy.sh --add-proxy          # 添加反向代理到宿主机服务

# ---- 重建 / 维护（不动数据） ----
./deploy.sh --rebuild-nginx      # 重建 Nginx 镜像（可切换类型）
./deploy.sh --rebuild-php        # 重建 PHP 镜像（可选版本）
./deploy.sh --rebuild-mysql      # 重建数据库（可选版本）
./deploy.sh --reset-mysql-password  # 重置 root 密码
./deploy.sh --reconfig           # 从 .env 重新生成配置并重建
./deploy.sh --cleanup            # 清理未使用的 Docker 资源
./deploy.sh --upgrade            # 升级脚本自身
./deploy.sh --uninstall          # 卸载并清理所有数据

# ---- 安全防护 ----
./deploy.sh --setup-waf          # 为现有部署启用 WAF + fail2ban + 解封面板
./deploy.sh --reset-f2b-password # 重置解封面板登录密码（用户名固定 admin）
./deploy.sh --update-f2b-panel   # 升级面板页面与 fail2ban 规则（保留密码与封禁数据）
./deploy.sh --f2b-status         # 查看被封禁的 IP
./deploy.sh --f2b-unban <IP>     # 解封指定 IP
./deploy.sh --f2b-ban <IP>       # 手动封禁指定 IP

# ---- 其他 ----
./deploy.sh --help               # 完整帮助（含数据库/Redis 操作速查）
./deploy.sh --version            # 版本号
```

---

## 🗄️ 数据库操作速查

> root 密码见 `lnmp/.credentials`。MySQL 8.0 镜像请把 `mariadb` / `mariadb-dump` 换成 `mysql` / `mysqldump`。

```bash
cd lnmp

# 进入命令行
docker compose exec mysql mariadb -uroot -p

# 查看所有数据库
docker compose exec mysql mariadb -uroot -p -e "SHOW DATABASES;"

# 查看各库占用大小 (MB)
docker compose exec mysql mariadb -uroot -p -e \
  "SELECT table_schema '库', ROUND(SUM(data_length+index_length)/1024/1024,2) 'MB' FROM information_schema.tables GROUP BY table_schema;"

# 忘记 / 重置 root 密码 (不影响数据)
./deploy.sh --reset-mysql-password
```

### 创建独立数据库 + 独立用户（每个网站一个）

```bash
# 1. 建库
docker compose exec mysql mariadb -uroot -p -e \
  "CREATE DATABASE IF NOT EXISTS dbname CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# 2. 建用户并只授权这个库
docker compose exec mysql mariadb -uroot -p -e \
  "CREATE USER IF NOT EXISTS 'user'@'%' IDENTIFIED BY 'password'; GRANT ALL ON dbname.* TO 'user'@'%'; FLUSH PRIVILEGES;"
```

网站程序里的数据库连接填写：主机 `mysql`（容器名，不是 127.0.0.1），端口 `3306`，库名、用户名、密码填上面创建的。

### 导入 / 导出单个数据库

> 带 `-T`（输入/输出重定向到文件）时容器里没有终端，`-p` 无法交互输入密码，所以这几条直接用容器内的 `$MYSQL_ROOT_PASSWORD` 环境变量，不用手动输密码。

```bash
# 导出
docker compose exec -T mysql sh -c 'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --events dbname' > dbname.sql

# 导入 (先按上面建好库；-T 不能少，否则重定向的 SQL 文件进不了容器)
docker compose exec -T mysql sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" dbname' < dbname.sql

# 导入 .sql.gz
gunzip < dbname.sql.gz | docker compose exec -T mysql sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" dbname'
```

### 迁移到新环境 / 从全库备份恢复（重要）

> ⚠️ 自动备份 `backups/db_*.sql` 使用 `--all-databases`，包含 `mysql` 系统库（账号权限表）。**整库导入新环境会覆盖新环境的 root 密码**，导致与 `.credentials` 不一致、登录失败、健康检查异常。
>
> **推荐：只导业务库，不碰 `mysql` 系统库**，新环境 root 密码保持不变。

```bash
# 1. 查看备份里有哪些库 (忽略 mysql/sys/information_schema/performance_schema)
grep -E "^-- Current Database:|^CREATE DATABASE" backups/db_YYYYmmdd_HHMMSS.sql

# 2. 在新环境先建好各业务库
#    (--one-database 靠 USE 语句过滤，CREATE DATABASE 行在 USE 之前会被过滤掉，所以要手动建)
docker compose exec mysql mariadb -uroot -p -e \
  "CREATE DATABASE IF NOT EXISTS dbname CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# 3. 逐个导入业务库 (只导该库，mysql 系统库那段被忽略)
docker compose exec -T mysql sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" --one-database dbname' < backups/db_YYYYmmdd_HHMMSS.sql

# 4. 验证表数量
docker compose exec mysql mariadb -uroot -p -e \
  "SELECT table_schema '库', COUNT(*) '表数' FROM information_schema.tables WHERE table_schema='dbname';"

# 5. 因为没导 mysql.user，按网站配置里的账号重建数据库用户 (账号密码一致就不用改网站配置)
docker compose exec mysql mariadb -uroot -p -e \
  "CREATE USER IF NOT EXISTS 'user'@'%' IDENTIFIED BY 'password'; GRANT ALL ON dbname.* TO 'user'@'%'; FLUSH PRIVILEGES;"
```

> 如果确实要整库全导（含账号表）：导入后新环境 root 密码会变成旧环境的。需要把旧环境 `.credentials` 和 `.env` 里的 `MYSQL_ROOT_PASS` 同步过来，再 `docker compose down && docker compose up -d`；连不上就用 `./deploy.sh --reset-mysql-password` 重置（不影响数据）。最后把旧环境 `volumes/php/www/` 下的站点目录拷到新环境同一路径。

---

## ☁️ 备份到云盘（rclone via Docker）

本地备份存在 `backups/`，服务器整体丢失时也会一起没。可选把每日备份额外推送到云盘（OneDrive / Google Drive / S3 等任何 [rclone 支持的存储](https://rclone.org/overview/)）。

推送通过**一次性 Docker 容器**跑 rclone 完成——复用你已有的 `rclone.conf`，无需在宿主机单独装 rclone，也不碰你现有的 rclone 容器。

```bash
# 前提: 已有一个配好 remote 的 rclone.conf (比如你已经用 Docker 跑着 rclone)。
# 若还没有，可临时跑官方镜像配置一个 remote:
#   docker run --rm -it -v /你的/rclone-config:/config rclone/rclone --config /config/rclone.conf config
#   如需云端也加密，建一个 crypt 类型的 remote 即可

sudo ./deploy.sh --setup-cloud-backup     # 或: 无参数运行 sudo ./deploy.sh 选「3) 配置云端备份」
# 向导会问:
#   - rclone 镜像 (回车用官方 rclone/rclone，或填你自己的镜像)
#   - rclone 配置目录 (宿主机上含 rclone.conf 的目录，手动输入绝对路径)
#   - 备份目标 (格式 remote名:路径，例如 myremote:lnmp-backup)
#   - 云端保留天数 (N 天 / 0 只留最新)
#   - Telegram Bot Token + Chat ID (选填，回车跳过；填了每次备份推送结果)
# 向导会用该镜像读配置、列出可用 remote、做连通性测试，通过后保存并可立即试跑一次。
```

配置完成后，每天凌晨 2 点的自动备份**成功后**会自动推送到云盘。要点：

- **用 `rclone copy`（Docker 一次性容器），不走挂载点**：先在本地生成完整备份，成功后起一个 `docker run --rm` 的 rclone 容器 copy 上去。`rclone copy` 会阻塞到上传完成并校验，真正确认到了云端——不像挂载点异步上传，`cp` 成功也不代表已传到云端。
- **先传新再删旧**：先上传带时间戳的新备份，确认成功后才清理云端旧备份。任意时刻云端至少有一份完整备份；某次备份损坏或网络中断都不会覆盖掉上一份好备份。
- **云端保留天数独立可调**：由 `.rclone-backup.env` 的 `CLOUD_RETENTION_DAYS` 控制，**与本地 `BACKUP_RETENTION_DAYS` 相互独立**——可以本地留 3 天、云端留 7 天。向导里设置：输入天数 `N` = 保留最近 N 天（删云端 age 超 N 天的）；`0` = 只留最新一份。手动编辑该文件时取值 `N` / `0` / `-1`（不自动删除，只增不减）；**留空或缺失该项时按 `-1` 处理（不删），绝不会误删异地备份**。
- **Telegram 推送结果（可选）**：配置 `TG_BOT_TOKEN` + `TG_CHAT_ID`（向导里选填，两者都填才启用）后，每次备份会把云端上传结果（成功/失败的文件、大小、保留策略）推送到 Telegram。token 通过 `curl -K -` 从标准输入传入，不会出现在宿主机进程列表（`ps`）里；凭据存在 600 权限的 `.rclone-backup.env`。先找 `@BotFather` 建 bot 拿 token、`@userinfobot` 拿 chat id。
- **本地仍保留**：`backups/` 按 `.env` 的 `BACKUP_RETENTION_DAYS`（默认 3 天）滚动保留，云盘是额外一层异地副本，两者互不影响。
- **配置独立、可手动定制**：所有参数（镜像、配置目录、容器内 conf 路径、目标 remote、云端保留天数、Telegram token/chat）写在 `.rclone-backup.env`（600 权限），格式同 `.env`、可手动编辑。它**不进** `.env`，所以 `--reconfig` 只会刷新备份脚本逻辑、**不会**冲掉你这份配置。想关闭云盘推送，删除该文件即可。
- **卸载不删云端**：`--uninstall` 不会动你的云盘备份（异地副本），只在结尾打印一条用 Docker 清理的命令供你手动执行。

---

## 🛡️ 安全模型（解封面板）

网页解封面板遵循权限隔离设计：

- PHP 面板**从不**直接调用 `fail2ban-client`，只向 `/var/f2b` 下的队列文件写入请求；
- 真正的封禁 / 解封操作由一个以 root 运行的桥接脚本每分钟执行；
- 面板入口受 Basic Auth 保护。

这样即使 PHP 侧被攻破，攻击者也拿不到 root 执行能力。

---

## 🤖 默认封禁的爬虫 / UA

主 `nginx.conf` 的 `http{}` 里用 `map $http_user_agent $bad_bot` 维护一份黑名单，命中的请求在 `waf-guard.conf` 里直接返回 `444`（断连、不回包、省带宽）。匹配大小写不敏感。

**国外 SEO / AI 采集类**
`SemrushBot` `AhrefsBot` `MJ12bot` `DotBot` `PetalBot` `Bytespider` `GPTBot` `ClaudeBot` `CCBot` `DataForSeoBot` `BLEXBot` `serpstatbot` `ZoominfoBot`

**中国采集 / SEO / 已停运搜索类**
`YisouSpider`（神马搜索，注意见下）`EasouSpider` `EasouBot` `JikeSpider` `EtaoSpider` `YoudaoBot` `YYSpider` `MauiBot` `LinkpadBot` `Ezooms`

**扫描器 / 异常客户端**
空 UA · `masscan` `nmap` `nikto` `sqlmap` `zgrab`

> `curl`、`wget`、`python-requests`、`Go-http-client` 等通用 HTTP 客户端**不封**：监控、接口调用、运维脚本都会用到，封禁会误伤，而且 fail2ban 会把来源 IP 一并封掉。

> **保留收录**：百度 `Baiduspider`、搜狗 `Sogou`、360 `360Spider` 等正规搜索引擎**未封**，不影响收录。
>
> **神马 `YisouSpider` 例外**：它本质是搜索引擎，封禁后神马搜索不会收录本站。这是按部署者要求显式加入的；如需放开收录，从黑名单移除即可。

**增删方法**：编辑 `deploy.sh` 中 `map $http_user_agent $bad_bot` 的两处正则（official 与 linuxserver 各一份），用 `|` 分隔追加，然后 `./deploy.sh --reconfig` 重新生成并重载。

验证：

```bash
curl -A "EasouSpider" -I https://你的域名/   # 被封：连接直接关闭
curl -A "Baiduspider" -I https://你的域名/   # 未封：正常 200
```

---

## 📝 更新日志

### v2.12.0 （2026-11-10）

**新增**
- **备份到云盘（rclone via Docker）**：新增 `--setup-cloud-backup`（无参数主菜单里也多了「3) 配置云端备份」入口），把每日备份额外推送到任意 rclone 支持的云存储（OneDrive / Google Drive / S3 等）。推送通过一次性 Docker 容器（默认官方 `rclone/rclone`，镜像可自定义）跑 `rclone copy`，复用你已有的 `rclone.conf`，无需宿主机装 rclone，也不碰你现有的 rclone 容器。`rclone copy` 阻塞到上传完成并校验，真正确认到云端（不像挂载点异步上传无法确认）；并**先传新再删旧**——先上传带时间戳的新备份、确认成功后才清理云端旧备份，任意时刻云端至少有一份完整备份，坏备份/网络中断都不会覆盖掉上一份好备份。**云端保留天数（`CLOUD_RETENTION_DAYS`）与本地 `BACKUP_RETENTION_DAYS` 独立**：向导里设 N 天或 0（只留最新）；手动编辑取 N / 0 / -1，**留空或缺失按 -1（不删）处理，绝不误删异地备份**。镜像 / 配置目录 / 目标 / 保留天数等参数都在独立的 `.rclone-backup.env`（600，可手动编辑；不进 `.env`，`--reconfig` 刷新备份脚本但不冲掉它）；本地 `backups/` 仍按原策略保留；`--uninstall` 不会删云端副本。向导要求手动输入配置目录（不自动探测，避免公开录屏/截图泄漏真实路径），并即时校验配置、列出可用 remote、测连通。
- **Telegram 推送备份结果（可选）**：云端备份配置里可填 `TG_BOT_TOKEN` + `TG_CHAT_ID`（向导里选填，两者都填才启用），每次备份把云端上传结果（成功/失败文件、大小、保留策略）推送到 Telegram。token 经 `curl -K -` 从 stdin 传入，不进宿主机进程列表（`ps`）；凭据存在 600 权限的 `.rclone-backup.env`。配置时会发一条测试消息验证 token/chat 是否有效。详见「☁️ 备份到云盘」。
- 无参数主菜单新增 **「3) 配置云端备份」** 入口（等价于 `--setup-cloud-backup`）。

### v2.11.0 （2026-11-09）

**新增**
- **默认启用 HTTP/3（QUIC）**：所有 HTTPS 站点（主域名、子域名、反向代理）在 `listen 443 ssl` 之外新增 `listen 443 quic` + `http3 on`，并通过 `Alt-Svc` 头通告浏览器可升级到 HTTP/3；`docker-compose.yml` 中三种 Nginx 方案都增加了 `443:443/udp` 端口映射。官方镜像（`nginx:alpine`，含自建 GeoIP2 版）、标准版与 `linuxserver/nginx` 都已内置 HTTP/3 模块，无需重新编译。
  - `reuseport` 在整份配置里只能出现一次，因此只有主域名的 server 块带 `reuseport`，子域名与反向代理不带，避免 nginx 启动冲突。`--reconfig` 迁移已有站点时**按 `server_name` 内容识别主域名**（不依赖文件名），改过名的环境也能正确认定。
  - 已部署的机器运行 `./deploy.sh --reconfig` 即可为现有站点配置补上 HTTP/3（幂等，已启用的跳过）。`--reconfig` 现在改配置前会整体备份 nginx 配置与 compose，`nginx -t` 不通过时自动整体还原，避免坏配置中断服务。
  - ⚠️ **需放行 UDP 443**：QUIC 走 UDP，宿主机防火墙 / 云安全组要额外放行 **UDP 443**，否则浏览器会静默回退到 HTTP/2。
  - ⚠️ **套 Cloudflare 橙云的域名**：浏览器到 CF 之间的 HTTP/3 由 CF 负责，而 **CF 回源不走 HTTP/3**，所以源站开 HTTP/3 对经 CF 代理的访客无感；真正用到源站 HTTP/3 的是直连 / 灰云 / 不过 CF 的域名。

### v2.10.0 （2026-10-29）

**新增**
- 无参数运行改为**交互式主菜单**：`1) 安装 LNMP`、`2) 安装 fail2ban`、`3) 配置云端备份`，带参数的运维子命令行为不变。
- 新增 `--reset-f2b-password` 子命令：重置网页解封面板登录密码（用户名固定 `admin`），回车留空自动生成 20 位强密码，明文补写 `.credentials`，无需重启容器。
- 安装完成界面的「访问地址」直接列出**网站首页 / 子域名 / 解封面板 `/f2b/` / phpMyAdmin**。
- 爬虫黑名单新增 `YisouSpider` 及一批中国采集 / SEO / 已停运搜索类爬虫（`EasouSpider`、`JikeSpider`、`EtaoSpider`、`YoudaoBot`、`YYSpider`、`MauiBot`、`LinkpadBot`、`Ezooms` 等）；保留百度 / 搜狗 / 360 收录。

- **解封面板增强**：封禁列表新增「国家/地区」列（国旗 + 中文名）与「来源」列（网站 / SSH），每页 10 条分页，点击 IP 即可复制；Top 攻击源 IP 图表完整显示全部 10 个 IP。国家信息用本地 GeoIP 库离线查询（[DB-IP IP to Country Lite](https://db-ip.com/db/download/ip-to-country-lite)，免费、无需注册，CC BY 4.0），**不把 IP 发给任何外部服务**；库文件存于 `volumes/geoip/`，由 `geoip_update.sh` 每月自动更新，下载失败时保留旧库。
- **网站套 Cloudflare 也能正确封禁**：
  - 真实 IP 还原改为**始终开启**（此前只在 Cloudflare 通配符证书时开启）。只信任来自 Cloudflare 官方网段的 `CF-Connecting-IP`，直连服务器的客户端伪造这个头无效；没套 CF 时规则不会命中，没有副作用。
  - 新增 **nginx 层封禁**：桥接脚本每分钟把 fail2ban 当前封禁的 IP 同步到 `f2b-banned.conf`，nginx 按真实访客 IP 直接返回 `444`。走 Cloudflare 时连到服务器的是 CF 节点，iptables 按访客 IP 拦不到，这一层才真正生效；被拦的请求不再写入访问日志，避免被重复计数、封禁无限续期。
  - Cloudflare 回源网段加入 fail2ban 白名单，即使真实 IP 还原失效，也不会把 CF 节点当成攻击者封掉（否则会误伤大批正常访客）。
- **iptables 封禁改用 ipset**：所有封禁 IP 放进一个集合，`DOCKER-USER` 链里只有一条匹配规则，封几千个 IP 也不会拖慢转发；`--update-f2b-panel` 会清掉旧版「每 IP 一条」的规则。
- **面板搜索**：封禁列表可按 IP 或网段前缀（如 `106.8.`）搜索，翻页保留搜索条件；输入完整 IP 时显示其当前状态（封禁中 / 白名单 / 未封禁）并直接提供解封、封禁、加白按钮。
- 新增 `--update-f2b-panel`：只升级面板页面、桥接脚本与 fail2ban 规则，**保留现有登录密码**（`--setup-waf` 会重新生成密码）。
- **SSH 爆破封禁**：fail2ban 新增 `sshd` jail（10 分钟内认证失败 5 次封 24 小时），自动探测 SSH 端口与日志来源（`auth.log` / `secure` / journald），探测不到则跳过、不影响网站 jail。白名单移到 `[DEFAULT]`，对网站和 SSH 同时生效；默认包含本机与全部局域网/内网网段（`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`100.64.0.0/10`、IPv6 `fc00::/7`、`fe80::/10`），每次重新生成配置都会补回这些网段，并保留你已加的白名单 IP。`--f2b-status` 同时显示两个 jail，`--f2b-unban` 与面板解封会一并解除 SSH 封禁。

**修复**
- **卸载可能误删整个目录**：此前脚本所在目录只要有一个 `.env` 就会被当成项目目录，若脚本放在 `/root` 且 `/root` 恰好有其他程序的 `.env`，`--uninstall` 会删掉整个 `/root`。现在必须同时有本脚本生成的 `.env` 与 `docker-compose.yml` 才认定为项目目录；卸载前会显示要删除的路径，并拒绝删除系统目录和用户主目录。
- **通配符证书 90 天后过期**：自动续期此前用普通 certbot 镜像，没有申请时用的 Cloudflare 插件，续期必然失败。现改用 `certbot/dns-cloudflare` 镜像续期（单域名证书同样适用）。
- **数据库备份在 MariaDB 11 上全部失败**：探测 `mariadb-dump` 的写法永远失败，一直回退到 MariaDB 11 已经删除的 `mysqldump`；容器名也写死成 `lnmp_mysql`。现已修正，导出改为 `--single-transaction`（不锁表），导出不完整时不保留残缺文件，备份文件只允许 root 读取。
- **日志轮转导致重复计数**：原来原地截断到 2M，fail2ban 会把保留的部分重新读一遍、重复计数。现改为改名为 `.log.1` 后让 nginx 重新打开日志。
- **IPv6 不封禁**：只封 IPv4；IPv6 一律放行（白名单加入 `::/0`，面板也不允许封禁 IPv6）。
- **ipset 封禁动作失效**：fail2ban 解析配置时会把「空格+分号」后的内容当注释截掉，旧写法 `case … ;;` 被截断，IP 实际没进 ipset。已改为不含分号的写法。
- **面板手动封禁白名单 IP**：fail2ban 的 `banip` 不检查白名单，误封 Cloudflare 节点或 Docker 网桥会让大量正常访问被丢包。桥接脚本现在会拒绝封禁白名单（含 CIDR 网段）内的 IP。
- **卸载连同备份一起删除**：从 `lnmp/deploy.sh` 运行卸载时，凭据备份写在项目目录里，随后被一并删掉。现在凭据和 `backups/` 数据库备份都移到项目目录的上一级保留。
- **`--update-f2b-panel` 失败可回滚**：升级前打包备份 nginx 配置与 compose；新配置 `nginx -t` 不通过或中途出错时自动还原并按旧配置重启 nginx，避免全站中断。
- **数据库密码不再出现在进程列表**：`docker exec -e MYSQL_PWD` 改为从环境继承，`ps` 看不到密码。
- **升级时 Nginx 类型被误改、子域名丢失**：旧版 `.env` 缺少 `NGINX_TYPE` / `INSTALL_PHPMYADMIN` 时，自动探测从未生效（脚本默认值让"是否为空"判断永远不成立），linuxserver / standard 部署升级后会被当成 official，网站打不开；`--setup-waf`、`--update-f2b-panel`、`--rebuild-nginx` 重写 `.env` 时会把子域名列表清空。所有入口现统一用 `load_existing_env` 读取已有配置。
- **从项目目录内运行脚本找不到配置**：安装时会复制一份到 `lnmp/deploy.sh`，此前从这里运行会去找 `lnmp/lnmp/`，所有命令失效。现在脚本所在目录有 `.env` 时就以它为项目目录。
- **已部署的机器上误选"安装 LNMP"会覆盖环境**：会生成新数据库密码（已有数据库仍是旧密码，网站连不上）并覆盖首页与站点配置。现在会先警告并要求输入 `yes` 确认，同时提示改用 `--reconfig`；已有网站首页不再被覆盖。
- **菜单 2 没有创建 `/f2b/` 入口**：主域名配置的查找规则太严（`server_name` 有多个域名时匹配不到），且 `set -e` 下找不到就直接退出，后续步骤都没执行。现改为在含 `listen 443` 的配置里查找，找不到会给出明确提示与手动方法；`--update-f2b-panel` 也会补建入口；面板入口只注入 HTTPS server 块。`--cert` 重签证书后会自动恢复入口。
- **fail2ban 暂时不可用时封禁名单被清空**：现在会保留上一次的名单，nginx 层封禁不会整批失效；面板解封、封禁、加白当轮即生效（原来要等下一分钟），加白对 SSH 也立即生效。
- **攻击者可让 fail2ban 漏计**：访问日志第二列原来记录客户端可控的 `$remote_user`，可借此让 fail2ban 的匹配或时间解析失效，现改为固定 `-`。敏感路径规则只看路径、不看参数，`?q=.env` 这类正常搜索和 `/.github/` 路径不再误计。
- **其他稳定性修复**：找不到 SSH 日志时显式关闭 sshd jail（否则整个 fail2ban 起不来）；封禁规则被防火墙重载清掉后 fail2ban 会自动恢复；`--reconfig` 会补装 ipset；`--rebuild-nginx` 不再允许在 linuxserver 与 official/standard 之间切换（目录结构不同，切换后网站会打不开）；`--uninstall` 会清理本项目的 fail2ban 配置与 ipset；`nginx -t` 失败时直接显示错误原因；`TERM` 未设置时不再在第一屏退出；多处找不到匹配时不再因 `set -e` 中途退出。
- **curl / wget 被误封**：UA 黑名单此前包含 `curl`、`Wget`、`python-requests`、`Go-http-client`、`libwww-perl`、`WinHttp`、`Hello`，命中即 444，fail2ban 再按 444 计数封禁来源 IP，导致服务器、监控和脚本被误封。现只保留真正的扫描器 UA。
- **fail2ban 启动失败**（`jail lnmp-nginx 不存在` / 服务 `failed`）：`setup_fail2ban_config` 现在会预先创建 nginx access 日志占位文件，避免 fail2ban 因 `logpath` 不存在而整体加载失败。
- **解封面板 `/f2b/` 返回 404**：面板静态目录此前只挂载到 php 容器，nginx 容器看不到文件。现已在三种 nginx（official / standard / linuxserver）的挂载中补上 `./fail2ban-panel:/var/www/html/_f2bapp:ro`。
- **nginx 启动报 `limit_req directive is duplicate`**：`inject_waf_include` 此前用 `sed /^server {/a` 会把 WAF include 同时插入 80 跳转块和 443 块，导致 `limit_req` 重复。现改为只在 `listen 443` 行后注入一次。
- **fail2ban 有拦截统计却从不封禁**：fail2ban 匹配前会删掉行内时间戳（剩 `[]`），原过滤正则 `\[[^\]]+\]` 要求括号内非空，导致一条都匹配不上（`Total failed` 恒为 0）。已改为 `\[[^\]]*\]`。
- **分布式扫描封不住**：fail2ban 封禁阈值由「60 秒 10 次封 1 小时」改为「1 小时 5 次封 24 小时」。扫描请求分散在大量 IP 上、单 IP 频率低，旧阈值永远达不到。
- **fail2ban / 桥接脚本 CPU 占用高**：过滤器显式指定 nginx 时间格式（`datepattern`），fail2ban 不再对每行逐个尝试时间模板；桥接脚本统计各封禁 IP 命中次数改为只扫一遍日志（原来每个 IP 各扫一遍），GeoIP 每个 IP 只查一次库；加锁防止上一轮没跑完时下一轮叠加，并降低桥接进程优先级。
- **日志无限增长**：新增 `log_rotate.sh`（每 5 分钟由 cron 执行），nginx 日志单个超过 **10M** 就改名为 `.log.1`（覆盖上一份）并让 nginx 重新打开日志，磁盘上最多约 20M。

**安全加固**
- **数据库密码不再暴露在进程列表**：备份脚本与密码重置改用 `MYSQL_PWD` 环境变量传递，不再用 `-p<密码>` 命令行参数（此前宿主机 `ps` / `docker top` 可见 root 密码，且每日定时备份反复暴露）。
- **fail2ban 桥接目录/队列文件收紧权限**：目录由 `0777` 改为 `0770` 并归属 PHP 容器 UID，队列文件由 `0666` 改为 `0660`（此前本机任意普通用户都能投递队列，借 root 桥接封禁或加白任意 IP）。
- **凭据备份文件权限修正**：卸载时的 `credentials_backup_*.txt` 改用 `install -m600` 创建，不再是 world-readable 的 `0644`。
- **面板配置文件限权**：`config/panel.php`（含 bcrypt 哈希与 secret）写入后设为 `0640`，宿主机其他本地用户不可读。
- **Cloudflare 真实客户端 IP 还原**：使用 Cloudflare DNS（通配符证书）时，主 `nginx.conf` 自动注入 `set_real_ip_from`（CF 官方网段）+ `real_ip_header CF-Connecting-IP`，使限流、日志、fail2ban 针对真实访客而非 CF 边缘 IP（否则会误封 Cloudflare 导致全站不可达）。
- **WAF 路径黑名单抗绕过**：`$bad_path` 的匹配变量由 `$request_uri`（原始未解码）改为 `$uri`（已解码+规范化），堵住 `/%2egit` 等百分号编码绕过。
- **解封面板登录锁定改为按 IP 计数**：此前全局计数，攻击者可持续失败把管理员永久锁死；现每个来源 IP 独立计数，单 IP 被锁不影响其他人。来源 IP 只取经 nginx 校验过的 `REMOTE_ADDR`，不再读取可被伪造的 `CF-Connecting-IP` / `X-Real-IP` 请求头；过期记录会被清理，锁定文件不会无限增长。
- **桥接脚本防符号链接攻击**：共享目录 `volumes/fail2ban/` 对 PHP 容器可写，root 运行的桥接脚本此前直接在里面建锁文件、写日志、截断队列，网站被攻破后可放置指向 `/etc/shadow` 等文件的符号链接，借 root 改写系统文件。现在锁、日志、缓存都放到 root 专属的 `/var/lib/lnmp-f2b/`，发布到共享目录一律"先写临时文件再原子替换"，队列文件是符号链接时直接丢弃。
- **升级不再误删自定义防火墙规则**：清理旧版封禁规则时只删除格式完全为「单个 IP + DROP」的规则，你自己加的带端口、协议条件的规则不受影响。
- **面板其他加固**：封禁名单文件只输出合法 IP（防止文件被篡改后在页面注入脚本）；表单参数是数组时按空值处理，不再触发 500；会话过期时返回 400 而非 403（403 会被 fail2ban 计数，可能把管理员自己封掉）；未登录访问接口时跳转到正确的登录页。
- **通配符证书断点续装不再死循环**：DNS 凭据（CF_TOKEN / 阿里云 / DNSPod）与数据库版本现随安装进度持久化，cert 阶段失败重跑不再因凭据丢失而反复失败。
- **手动数据库密码字符校验**：手动输入 MySQL 密码时限制为 `A-Z a-z 0-9 ._-+=@`，避免特殊字符破坏 `.env` 解析（自动生成的密码不受影响）。

> 升级到本版本后，若要让上述修复与挂载变更作用到**已有部署**，运行 `./deploy.sh --reconfig`（不影响数据、证书与站点文件）。

---

## 📄 License

按仓库 LICENSE 文件约定。
