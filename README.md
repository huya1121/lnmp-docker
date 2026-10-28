# LNMP Docker 一键部署脚本

> **L**inux + **N**ginx + **M**ySQL/MariaDB + **P**HP + **R**edis，基于 Docker 的生产级自动化部署脚本。
>
> 版本 **v2.9.0** · 单文件 `deploy.sh` · 交互式向导 + 全套运维子命令

一条命令把一台干净的 Linux 服务器变成带 **自动 HTTPS、WAF 防护、fail2ban 封禁、定时备份** 的 LNMP 环境。所有服务跑在 Docker 容器里，互不污染宿主机。

---

## ✨ 核心特性

- **一键安装向导** — 交互式选择 PHP / 数据库 / Nginx 版本、域名、证书类型，全程自动。
- **自动 HTTPS** — 集成 certbot，支持单域名证书与 DNS 通配符证书（Cloudflare / 阿里云 / DNSPod），并自动续期。
- **三种 Nginx 方案**
  - `official` — 官方 nginx:alpine + 自动编译 GeoIP2 动态模块（跟随最新稳定版）
  - `linuxserver` — linuxserver/nginx，预装 GeoIP2，开箱即用
  - `standard` — 官方 nginx:alpine 标准版，无 GeoIP2，构建最快
- **安全防护（WAF + fail2ban）**
  - 恶意 UA / 扫描路径直接 `444` 断连，省带宽
  - 请求限速 / 并发限制，超限返回 `429`
  - fail2ban 捕获 429 累计自动封禁 IP
  - 自带**网页解封面板**（Basic Auth 保护，PHP 只写队列、root 桥接脚本执行，权限隔离）
- **定时备份** — 自动备份数据库与配置，按天数滚动保留（默认 3 天）。
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
| PHP 扩展 | mysqli, pdo_mysql, curl, zip, mbstring, xml, gd, intl, opcache, bcmath, exif, redis | — |

---

## 🚀 快速开始

> 要求：一台可联网的 Linux 服务器（脚本会自动安装 Docker 与 compose 插件），域名已解析到本机 IP，具备 root 权限。

```bash
# 1. 下载脚本
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/huya1121/lnmp-docker/main/deploy.sh
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

# 创建库
docker compose exec mysql mariadb -uroot -p -e "CREATE DATABASE dbname CHARACTER SET utf8mb4;"

# 创建用户并授权
docker compose exec mysql mariadb -uroot -p -e \
  "CREATE USER 'user'@'%' IDENTIFIED BY 'password'; GRANT ALL ON dbname.* TO 'user'@'%'; FLUSH PRIVILEGES;"

# 备份 / 恢复
docker compose exec mysql mariadb-dump -uroot -p dbname > backup.sql
docker compose exec -T mysql mariadb -uroot -p dbname < backup.sql
```

### 迁移到新环境的注意事项

自动备份使用 `--all-databases`，其中包含 `mysql` 系统库（账号权限表）。**整库导入新环境会覆盖新环境的 root 密码**，导致与 `.credentials` 不一致、登录失败。

**推荐：只导业务库，用 `--one-database` 过滤**，新环境 root 密码保持不变，再按应用配置重建业务用户。完整步骤见安装后生成的 `lnmp/README.md`。

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
空 UA · `python-requests` `Go-http-client` `libwww-perl` `curl/` `Wget` `masscan` `nmap` `nikto` `sqlmap` `zgrab` `WinHttp` `Hello`

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

## 📄 License

按仓库 LICENSE 文件约定。
