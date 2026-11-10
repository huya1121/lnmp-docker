#!/usr/bin/env bash
set -eo pipefail

# ======================== 版本和配置 ========================
VERSION="2.11.0"
SCRIPT_URL="https://raw.githubusercontent.com/huya1121/lnmp-docker/main/deploy.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/lnmp"
# 脚本本身就在项目目录里 (安装时会复制一份到 lnmp/deploy.sh) 时，项目目录就是脚本所在目录，
# 否则从 lnmp/deploy.sh 运行会去找 lnmp/lnmp，所有命令都找不到 .env。
# 判断要严格: 必须同时有本脚本生成的 .env 和 compose 文件。只看 .env 的话，脚本放在 /root
# 而 /root 恰好有别的程序的 .env 时，项目目录会变成 /root，--uninstall 会删掉整个 /root
is_lnmp_project_dir() {
    [[ -f "$1/.env" && -f "$1/docker-compose.yml" ]] \
        && grep -q '^MYSQL_ROOT_PASS=' "$1/.env" 2>/dev/null \
        && grep -q 'container_name: \${PROJECT_NAME}_nginx' "$1/docker-compose.yml" 2>/dev/null
}
# 用「lnmp/ 不是项目」而不是「lnmp/ 不存在」: 旧版本 bug 可能残留一个空的 lnmp/lnmp 目录
if ! is_lnmp_project_dir "$PROJECT_DIR" && is_lnmp_project_dir "$SCRIPT_DIR"; then
    PROJECT_DIR="$SCRIPT_DIR"
fi
PROJECT_NAME="lnmp"
PHP_VERSION="8.2"
MARIADB_VERSION="10.11"
MYSQL_DB="myapp"
BACKUP_RETENTION_DAYS=3
BACKUP_DIR="$PROJECT_DIR/backups"
BACKUP_SCRIPT="$PROJECT_DIR/backup_task.sh"
CREDENTIALS_FILE="$PROJECT_DIR/.credentials"
README_FILE="$PROJECT_DIR/README.md"
PROGRESS_FILE="$PROJECT_DIR/.install_progress"
CERT_TYPE="single"
DNS_PROVIDER=""
SUBDOMAINS=()
DOMAIN=""
INSTALL_PHPMYADMIN="no"
NGINX_TYPE="official"  # official (with geoip2 build) or linuxserver
# Cloudflare 官方回源网段 (https://www.cloudflare.com/ips/)。nginx 只信任这些来源发来的
# CF-Connecting-IP；fail2ban 白名单也包含它们，避免把 CF 节点当攻击者封掉。
CF_IP_RANGES="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
# 官方 Nginx 镜像基于 nginx:alpine (始终为最新稳定版)。GeoIP2 动态模块会在
# 构建时自动探测该基础镜像的 nginx 版本并下载对应源码编译，
# 因此无需在此固定版本号 —— 永远跟随最新 nginx。

# 颜色和样式
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# 图标
ICON_OK="✓"
ICON_FAIL="✗"
ICON_WARN="⚠"
ICON_INFO="ℹ"
ICON_ROCKET="🚀"
ICON_LOCK="🔒"
ICON_GLOBE="🌐"
ICON_FOLDER="📁"
ICON_DATABASE="🗄"
ICON_GEAR="⚙"
ICON_CLOCK="🕐"

# ======================== 工具函数 ========================
log() { echo -e "${GREEN}[${ICON_OK}]${NC} $1"; }
warn() { echo -e "${YELLOW}[${ICON_WARN}]${NC} $1"; }
error() { echo -e "${RED}[${ICON_FAIL}]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[${ICON_INFO}]${NC} $1"; }

step() {
    echo ""
    echo -e "${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} ${BOLD}$1${NC}"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
}

# 进度条函数
progress_bar() {
    local current=$1 total=$2 width=40
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    printf "\r${CYAN}["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "]${NC} ${BOLD}%3d%%${NC}" $percent
}

# 旋转加载动画
spinner() {
    local pid=$1 msg="${2:-加载中...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        local idx=$((i % 10))
        printf "\r${CYAN}%s${NC} %s" "${spin:idx:1}" "$msg"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r"
}

# 密码输入 (已简化，直接在调用处使用 read)

# 生成强密码
generate_strong_password() {
    local length=${1:-24}
    local result=""
    
    # Method 1: Use /dev/urandom (most reliable)
    if [[ -r /dev/urandom ]]; then
        result=$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$length") || true
    fi
    
    # Method 2: Use openssl if urandom failed
    if [[ ${#result} -lt $length ]] && command -v openssl &>/dev/null; then
        result=$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | cut -c1-"$length") || true
    fi
    
    # Method 3: Use date + sha256sum as fallback
    if [[ ${#result} -lt $length ]]; then
        if command -v sha256sum &>/dev/null; then
            result=$(echo "$(date +%s%N)$$" | sha256sum | tr -dc 'a-zA-Z0-9' | cut -c1-"$length") || true
        elif command -v shasum &>/dev/null; then
            result=$(echo "$(date +%s%N)$$" | shasum -a 256 | tr -dc 'a-zA-Z0-9' | cut -c1-"$length") || true
        fi
    fi
    
    # Final fallback - use multiple sources for entropy
    if [[ -z "$result" || ${#result} -lt 8 ]]; then
        # Combine multiple entropy sources for better randomness
        local entropy="${RANDOM}$(date +%s%N)$$${BASHPID:-0}$(hostname 2>/dev/null)"
        if command -v md5sum &>/dev/null; then
            result=$(echo "$entropy" | md5sum | tr -dc 'a-zA-Z0-9' | cut -c1-"$length")
        elif command -v md5 &>/dev/null; then
            result=$(echo "$entropy" | md5 | tr -dc 'a-zA-Z0-9' | cut -c1-"$length")
        else
            result="Secure${RANDOM}Pass$(date +%s)${RANDOM}"
        fi
    fi
    
    printf '%s' "$result"
}

# 验证域名格式
validate_domain() {
    local domain=$1
    # 检查域名格式是否合法
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# 验证子域名格式
validate_subdomain() {
    local subdomain=$1
    # 子域名只能包含字母、数字和连字符
    if [[ ! "$subdomain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

# 获取 MariaDB/MySQL 镜像名称
get_mariadb_image() {
    if [[ "$MARIADB_VERSION" == mysql:* ]]; then
        echo "${MARIADB_VERSION}"
    else
        echo "mariadb:${MARIADB_VERSION}"
    fi
}

# 检查磁盘空间
check_disk_space() {
    local required_mb=${1:-2000}
    local available_mb=0
    
    # 1. 优先用 stat -f 直接读文件系统块信息（可用块数 × 块大小），
    #    不依赖设备名/df 输出格式，在 Incus/LXC 的 ZFS 后端下同样可靠。
    available_mb=$(stat -f -c '%a %S' "$SCRIPT_DIR" 2>/dev/null | awk '{
        if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) printf "%d", ($1 * $2) / 1048576
    }')

    # 2. 兜底：stat 不可用时用 df --output=avail（只输出数字，免疫换行）
    if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
        available_mb=$(df -m --output=avail "$SCRIPT_DIR" 2>/dev/null | tail -n 1 | tr -d '[:space:]')
    fi

    # 3. 再兜底：老版本 df 不支持 --output，用 xargs 压成单行后按字段数解析
    if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
        available_mb=$(df -m "$SCRIPT_DIR" 2>/dev/null | xargs | awk '{
            print (NF > 6) ? $(NF-2) : $4   # 文件系统名换行时可用空间在倒数第三列，否则在第四列
        }')
    fi

    # Ensure we got a valid number
    if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
        warn "无法检测磁盘空间"
        return 0  # Don't fail if we can't detect
    fi
    
    if [[ $available_mb -lt $required_mb ]]; then
        warn "磁盘空间不足！需要 ${required_mb}MB，可用 ${available_mb}MB"
        return 1
    fi
    return 0
}
# ======================== 服务器配置检测 ========================
# 全局变量存储检测结果
SERVER_MEM_MB=1024
SERVER_CPU_CORES=1
SERVER_TIER="medium"

# 检测服务器配置
detect_server_config() {
    step "${ICON_GEAR} 检测服务器配置"
    
    # 检测内存 (MB) - cross-platform
    if command -v free &>/dev/null; then
        SERVER_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 1024)
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use sysctl
        SERVER_MEM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 1073741824) / 1024 / 1024 ))
    else
        SERVER_MEM_MB=1024
    fi
    
    # 检测 CPU 核心数 - cross-platform
    if command -v nproc &>/dev/null; then
        SERVER_CPU_CORES=$(nproc 2>/dev/null || echo 1)
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use sysctl
        SERVER_CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    elif [[ -f /proc/cpuinfo ]]; then
        SERVER_CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    else
        SERVER_CPU_CORES=1
    fi
    
    # 根据内存确定配置档位
    if [[ $SERVER_MEM_MB -lt 1024 ]]; then
        SERVER_TIER="low"
    elif [[ $SERVER_MEM_MB -lt 2048 ]]; then
        SERVER_TIER="medium"
    elif [[ $SERVER_MEM_MB -lt 4096 ]]; then
        SERVER_TIER="high"
    else
        SERVER_TIER="ultra"
    fi
    
    echo -e "    ${DIM}├─ 内存: ${NC}${CYAN}${SERVER_MEM_MB}MB${NC}"
    echo -e "    ${DIM}├─ CPU: ${NC}${CYAN}${SERVER_CPU_CORES} 核心${NC}"
    echo -e "    ${DIM}└─ 优化档位: ${NC}${CYAN}${SERVER_TIER}${NC} ${DIM}(low/medium/high/ultra)${NC}"
    
    log "服务器配置检测完成"
}

# 获取 MySQL 优化参数 (根据服务器配置)
get_mysql_innodb_buffer() {
    case "$SERVER_TIER" in
        low)    echo "64M" ;;
        medium) echo "128M" ;;
        high)   echo "256M" ;;
        ultra)  echo "$(( SERVER_MEM_MB / 4 ))M" ;;
    esac
}

get_mysql_max_connections() {
    case "$SERVER_TIER" in
        low)    echo "50" ;;
        medium) echo "100" ;;
        high)   echo "200" ;;
        ultra)  echo "500" ;;
    esac
}

get_mysql_table_cache() {
    case "$SERVER_TIER" in
        low)    echo "100" ;;
        medium) echo "200" ;;
        high)   echo "400" ;;
        ultra)  echo "800" ;;
    esac
}

get_mysql_tmp_table() {
    case "$SERVER_TIER" in
        low)    echo "16M" ;;
        medium) echo "32M" ;;
        high)   echo "64M" ;;
        ultra)  echo "128M" ;;
    esac
}

# 获取 PHP 优化参数
get_php_memory_limit() {
    case "$SERVER_TIER" in
        low)    echo "64M" ;;
        medium) echo "128M" ;;
        high)   echo "256M" ;;
        ultra)  echo "512M" ;;
    esac
}

get_php_opcache_memory() {
    case "$SERVER_TIER" in
        low)    echo "32" ;;
        medium) echo "64" ;;
        high)   echo "128" ;;
        ultra)  echo "256" ;;
    esac
}

# 根据实际可用内存计算 pm.max_children，避免 PHP-FPM 进程数 × memory_limit
# 超过物理内存导致 OOM (爆内存)。原来的固定档位值 (如 medium=25) 在
# 25 × 128M = 3.2G 时会远超中低配服务器内存。
get_php_pm_max_children() {
    # 每个子进程的内存上限 (memory_limit, 去掉 M 后缀)
    local mem_limit; mem_limit=$(get_php_memory_limit); mem_limit=${mem_limit%M}

    # 实际平均每进程占用按 memory_limit 的一半估算 (极少请求会吃满上限)，最低 32M
    local per_child=$(( mem_limit / 2 ))
    [[ $per_child -lt 32 ]] && per_child=32

    # 预留内存给 MySQL / Redis / 系统后，PHP 可用内存约为总内存的 45%
    local php_avail=$(( SERVER_MEM_MB * 45 / 100 ))
    local result=$(( php_avail / per_child ))

    # 保留原有档位作为上限，内存充足时不会超过原来的行为
    local cap
    case "$SERVER_TIER" in
        low)    cap=10 ;;
        medium) cap=25 ;;
        high)   cap=50 ;;
        ultra)
            cap=$(( SERVER_CPU_CORES * 10 ))
            [[ $cap -lt 50 ]] && cap=50
            [[ $cap -gt 200 ]] && cap=200
            ;;
    esac
    [[ $result -gt $cap ]] && result=$cap
    [[ $result -lt 4 ]] && result=4
    echo "$result"
}

get_php_pm_start_servers() {
    local max_children=$(get_php_pm_max_children)
    local n=$(( max_children / 5 ))
    # PHP-FPM 动态模式要求该值 >= 1，低内存下 max_children 较小时需兜底
    [[ $n -lt 1 ]] && n=1
    echo "$n"
}

get_php_pm_min_spare() {
    local max_children=$(get_php_pm_max_children)
    local n=$(( max_children / 5 ))
    # pm.min_spare_servers 必须为正数，否则 PHP-FPM 拒绝启动
    [[ $n -lt 1 ]] && n=1
    echo "$n"
}

get_php_pm_max_spare() {
    local max_children=$(get_php_pm_max_children)
    echo $(( max_children * 7 / 10 ))
}

# 获取 Nginx 优化参数
get_nginx_worker_connections() {
    case "$SERVER_TIER" in
        low)    echo "512" ;;
        medium) echo "1024" ;;
        high)   echo "2048" ;;
        ultra)  echo "4096" ;;
    esac
}

get_nginx_client_body_buffer() {
    case "$SERVER_TIER" in
        low)    echo "8k" ;;
        medium) echo "16k" ;;
        high)   echo "16k" ;;
        ultra)  echo "32k" ;;
    esac
}

# Redis 最大内存 (根据服务器配置，避免固定 128M 在低配机上挤占内存)
get_redis_maxmemory() {
    case "$SERVER_TIER" in
        low)    echo "64mb" ;;
        medium) echo "128mb" ;;
        high)   echo "256mb" ;;
        ultra)  echo "512mb" ;;
    esac
}

# ======================== 进度管理 ========================
save_progress() {
    local stage=$1
    mkdir -p "$PROJECT_DIR"
    # 正确保存数组格式
    local subdomains_str=""
    for sub in "${SUBDOMAINS[@]}"; do
        subdomains_str+="\"$sub\" "
    done
    # 密码可能含空格/$/#/引号等特殊字符，用 printf %q 生成可被 source 安全还原的转义形式，
    # 避免写入时被截断、恢复进度时读到错误密码
    {
        echo "STAGE=$stage"
        echo "DOMAIN=$DOMAIN"
        echo "CERT_TYPE=$CERT_TYPE"
        echo "DNS_PROVIDER=$DNS_PROVIDER"
        printf 'MYSQL_ROOT_PASS=%q\n' "$MYSQL_ROOT_PASS"
        printf 'REDIS_PASSWORD=%q\n' "$REDIS_PASSWORD"
        echo "PHP_VERSION=$PHP_VERSION"
        echo "MARIADB_VERSION=$MARIADB_VERSION"
        echo "INSTALL_PHPMYADMIN=$INSTALL_PHPMYADMIN"
        echo "INSTALL_FAIL2BAN=${INSTALL_FAIL2BAN:-yes}"
        echo "NGINX_TYPE=$NGINX_TYPE"
        echo "SUBDOMAINS=(${subdomains_str})"
        # DNS 通配符证书凭据：续装时 config 阶段会被跳过，不持久化会导致
        # cert 阶段重跑时凭据为空、certbot 永远失败而死循环 (用 %q 安全转义)
        printf 'CF_TOKEN=%q\n'    "${CF_TOKEN:-}"
        printf 'ALI_KEY=%q\n'     "${ALI_KEY:-}"
        printf 'ALI_SECRET=%q\n'  "${ALI_SECRET:-}"
        printf 'DP_ID=%q\n'       "${DP_ID:-}"
        printf 'DP_TOKEN=%q\n'    "${DP_TOKEN:-}"
    } > "$PROGRESS_FILE"
    # 进度文件含数据库/Redis 密码，限制为仅 root 可读
    chmod 600 "$PROGRESS_FILE" 2>/dev/null || true
}

load_progress() { [[ -f "$PROGRESS_FILE" ]] && source "$PROGRESS_FILE" && return 0; return 1; }

# 读取已有部署的配置，供 --reconfig / --setup-waf / --update-f2b-panel 等入口共用。
# 1) NGINX_TYPE / INSTALL_PHPMYADMIN 脚本开头有默认值，旧版 .env 没有这两个键时 source 后
#    仍是默认值，判断"是否为空"永远不成立 —— 必须先 unset，缺键时才能真正走探测。
# 2) .env 里子域名存成 SUBDOMAINS_LIST 字符串，要还原回 SUBDOMAINS 数组，
#    否则后面重写 .env 时会写成空，子域名记录永久丢失。
load_existing_env() {
    [[ -f "$PROJECT_DIR/.env" ]] || error "未找到 $PROJECT_DIR/.env，请先完成初始安装"
    unset NGINX_TYPE INSTALL_PHPMYADMIN
    source "$PROJECT_DIR/.env"
    # 进度文件里只取这两个值；不整体 source —— 里面的域名、密码可能是另一次未完成安装的旧值，
    # 会覆盖 .env 里正在使用的配置
    if [[ -f "$PROGRESS_FILE" ]]; then
        local pv
        if [[ -z "${NGINX_TYPE:-}" ]]; then
            pv=$(grep -m1 '^NGINX_TYPE=' "$PROGRESS_FILE" 2>/dev/null | cut -d= -f2-) || true
            [[ "$pv" =~ ^(official|standard|linuxserver)$ ]] && NGINX_TYPE="$pv"
        fi
        if [[ -z "${INSTALL_PHPMYADMIN:-}" ]]; then
            pv=$(grep -m1 '^INSTALL_PHPMYADMIN=' "$PROGRESS_FILE" 2>/dev/null | cut -d= -f2-) || true
            [[ "$pv" =~ ^(yes|no)$ ]] && INSTALL_PHPMYADMIN="$pv"
        fi
    fi
    local compose_file="$PROJECT_DIR/docker-compose.yml"
    if [[ -z "${NGINX_TYPE:-}" ]]; then
        if grep -q "linuxserver/nginx" "$compose_file" 2>/dev/null; then
            NGINX_TYPE="linuxserver"
        elif grep -qE "image:[[:space:]]*nginx:alpine" "$compose_file" 2>/dev/null; then
            NGINX_TYPE="standard"
        else
            # 含 lnmp-nginx-geoip2 或 nginx 使用 build: 均视为 official；兜底也是 official
            NGINX_TYPE="official"
        fi
        info "自动探测 NGINX_TYPE=$NGINX_TYPE"
    fi
    if [[ -z "${INSTALL_PHPMYADMIN:-}" ]]; then
        if grep -q "phpmyadmin:" "$compose_file" 2>/dev/null; then
            INSTALL_PHPMYADMIN="yes"
        else
            INSTALL_PHPMYADMIN="no"
        fi
        info "自动探测 INSTALL_PHPMYADMIN=$INSTALL_PHPMYADMIN"
    fi
    CERT_TYPE="${CERT_TYPE:-single}"
    DNS_PROVIDER="${DNS_PROVIDER:-}"
    # SUBDOMAINS_LIST 非空才覆盖，否则沿用进度文件恢复的 SUBDOMAINS
    if [[ -n "${SUBDOMAINS_LIST:-}" ]]; then
        read -r -a SUBDOMAINS <<< "$SUBDOMAINS_LIST"
    fi
    # 关键值缺失时不能继续，否则会写出空密码的 .env，redis 等服务起不来
    [[ -n "${DOMAIN:-}" ]] || error ".env 中缺少 DOMAIN，无法继续"
    [[ -n "${MYSQL_ROOT_PASS:-}" && -n "${REDIS_PASSWORD:-}" ]] || error ".env 中缺少数据库/Redis 密码，无法继续"
}
clear_progress() { rm -f "$PROGRESS_FILE"; }

# ======================== 显示函数 ========================
show_banner() {
    clear 2>/dev/null || true   # TERM 未设置 (如 cron / 非交互) 时 clear 返回非零，set -e 下会直接退出
    echo -e "${CYAN}"
    echo "    ██╗     ███╗   ██╗███╗   ███╗██████╗ "
    echo "    ██║     ████╗  ██║████╗ ████║██╔══██╗"
    echo "    ██║     ██╔██╗ ██║██╔████╔██║██████╔╝"
    echo "    ██║     ██║╚██╗██║██║╚██╔╝██║██╔═══╝ "
    echo "    ███████╗██║ ╚████║██║ ╚═╝ ██║██║     "
    echo "    ╚══════╝╚═╝  ╚═══╝╚═╝     ╚═╝╚═╝     "
    echo -e "${NC}"
    echo -e "${DIM}    Linux + Nginx + MySQL + PHP + Redis${NC}"
    echo -e "${DIM}    Docker 自动化部署脚本 v${VERSION}${NC}"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

show_help() {
    show_banner
    echo -e "${BOLD}用法:${NC} $0 [选项]"
    echo ""
    echo -e "${BOLD}安装和部署:${NC}"
    echo -e "  ${CYAN}(无参数)${NC}         完整安装向导"
    echo -e "  ${CYAN}--cert, -c${NC}       单独申请/重新申请 SSL 证书"
    echo -e "  ${CYAN}--renew${NC}          续期已有的 SSL 证书"
    echo ""
    echo -e "${BOLD}服务管理:${NC}"
    echo -e "  ${CYAN}--status${NC}         查看服务运行状态"
    echo -e "  ${CYAN}--restart${NC}        重启所有服务"
    echo -e "  ${CYAN}--stop${NC}           停止所有服务"
    echo -e "  ${CYAN}--logs [服务]${NC}    查看日志 (nginx/php/mysql/redis)"
    echo ""
    echo -e "${BOLD}备份和维护:${NC}"
    echo -e "  ${CYAN}--backup${NC}         立即执行备份"
    echo -e "  ${CYAN}--setup-cloud-backup${NC}  配置备份到云盘 (rclone，先传新再删旧)"
    echo -e "  ${CYAN}--info${NC}           显示当前配置信息"
    echo -e "  ${CYAN}--health${NC}         健康检查"
    echo ""
    echo -e "${BOLD}高级操作:${NC}"
    echo -e "  ${CYAN}--add-subdomain${NC}  添加新子域名"
    echo -e "  ${CYAN}--del-subdomain${NC}  删除子域名 (可带名称，如 --del-subdomain api)"
    echo -e "  ${CYAN}--add-proxy${NC}      添加反向代理到宿主机服务"
    echo -e "  ${CYAN}--rebuild-nginx${NC}  重新构建 Nginx 镜像 (可切换类型)"
    echo -e "  ${CYAN}--rebuild-php${NC}    重新构建 PHP 镜像 (可选择版本)"
    echo -e "  ${CYAN}--rebuild-mysql${NC}  重建 MySQL/MariaDB (可选择版本)"
    echo -e "  ${CYAN}--reset-mysql-password${NC}  重置 MySQL/MariaDB root 密码 (不影响数据)"
    echo -e "  ${CYAN}--reconfig${NC}       从现有 .env 重新生成配置并重建 (应用时区/内存/续期/备份等修复，不动数据)"
    echo -e "  ${CYAN}--uninstall${NC}      卸载并清理所有数据"
    echo -e "  ${CYAN}--upgrade${NC}        升级脚本到最新版本"
    echo -e "  ${CYAN}--cleanup${NC}        清理未使用的 Docker 资源"
    echo ""
    echo -e "${BOLD}安全防护 (WAF + fail2ban):${NC}"
    echo -e "  ${CYAN}--setup-waf${NC}      为现有部署启用 WAF + fail2ban + 网页解封面板"
    echo -e "  ${CYAN}--reset-f2b-password${NC}  重置网页解封面板登录密码 (用户名固定 admin)"
    echo -e "  ${CYAN}--update-f2b-panel${NC}    升级面板页面与 fail2ban 规则 (保留密码与封禁数据)"
    echo -e "  ${CYAN}--f2b-status${NC}     查看当前被封禁的 IP"
    echo -e "  ${CYAN}--f2b-unban <IP>${NC} 解封指定 IP"
    echo -e "  ${CYAN}--f2b-ban <IP>${NC}   手动封禁指定 IP"
    echo ""
    echo -e "${BOLD}其他:${NC}"
    echo -e "  ${CYAN}--help, -h${NC}       显示此帮助信息"
    echo -e "  ${CYAN}--version, -v${NC}    显示版本号"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${ICON_DATABASE} MySQL/MariaDB 操作指南${NC}"
    echo ""
    echo -e "${DIM}  进入数据库命令行:${NC}"
    echo -e "    docker compose exec mysql mysql -u root -p"
    echo ""
    echo -e "${DIM}  创建新数据库:${NC}"
    echo -e "    docker compose exec mysql mysql -u root -p -e \"CREATE DATABASE dbname;\""
    echo ""
    echo -e "${DIM}  创建用户并授权:${NC}"
    echo -e "    docker compose exec mysql mysql -u root -p -e \\"
    echo -e "      \"CREATE USER 'user'@'%' IDENTIFIED BY 'password';\""
    echo -e "    docker compose exec mysql mysql -u root -p -e \\"
    echo -e "      \"GRANT ALL ON dbname.* TO 'user'@'%'; FLUSH PRIVILEGES;\""
    echo ""
    echo -e "${DIM}  备份数据库:${NC}"
    echo -e "    docker compose exec mysql mysqldump -u root -p dbname > backup.sql"
    echo -e "    docker compose exec mysql mysqldump -u root -p --all-databases > all_backup.sql"
    echo ""
    echo -e "${DIM}  恢复数据库:${NC}"
    echo -e "    docker compose exec -T mysql mysql -u root -p dbname < backup.sql"
    echo ""
    echo -e "${DIM}  查看数据库列表:${NC}"
    echo -e "    docker compose exec mysql mysql -u root -p -e \"SHOW DATABASES;\""
    echo ""
    echo -e "${DIM}  查看数据库大小:${NC}"
    echo -e "    docker compose exec mysql mysql -u root -p -e \\"
    echo -e "      \"SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,2) AS 'Size(MB)'\\"
    echo -e "       FROM information_schema.tables GROUP BY table_schema;\""
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${ICON_GEAR} Redis 操作指南${NC}"
    echo ""
    echo -e "${DIM}  进入 Redis 命令行:${NC}"
    echo -e "    docker compose exec redis redis-cli -a \$REDIS_PASSWORD"
    echo ""
    echo -e "${DIM}  查看所有 key:${NC}"
    echo -e "    docker compose exec redis redis-cli -a \$REDIS_PASSWORD KEYS '*'"
    echo ""
    echo -e "${DIM}  清空缓存:${NC}"
    echo -e "    docker compose exec redis redis-cli -a \$REDIS_PASSWORD FLUSHALL"
    echo ""
    echo -e "${DIM}  查看内存使用:${NC}"
    echo -e "    docker compose exec redis redis-cli -a \$REDIS_PASSWORD INFO memory"
    echo ""
}

show_version() {
    echo -e "${CYAN}LNMP Docker 部署脚本${NC} v${VERSION}"
    exit 0
}

show_cert_retry_hint() {
    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC}  ${ICON_WARN} ${BOLD}证书申请失败${NC}                                              ${YELLOW}│${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  请检查以下问题:                                               ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}    1. 域名 DNS 解析是否已生效                                  ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}    2. API Token/密钥是否正确                                   ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}    3. 防火墙是否已开放 80/443 端口                             ${YELLOW}│${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  重新申请: ${GREEN}$0 --cert${NC}                                  ${YELLOW}│${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# ======================== 环境检查 ========================
check_env() {
    [[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"
    step "${ICON_GEAR} 检查系统环境"
    
    # 检查操作系统
    if [[ -f /etc/os-release ]]; then
        # 在子 shell 中读取，避免 /etc/os-release 里的 VERSION= 覆盖脚本全局 VERSION
        local os_name os_id os_version_id
        os_name=$(. /etc/os-release 2>/dev/null; printf '%s' "$NAME")
        os_id=$(. /etc/os-release 2>/dev/null; printf '%s' "$ID")
        os_version_id=$(. /etc/os-release 2>/dev/null; printf '%s' "$VERSION_ID")
        info "操作系统: $os_name $os_version_id"
        case "$os_id" in
            debian|ubuntu)
                ;;
            centos|rhel|fedora|rocky|almalinux)
                warn "检测到 RHEL 系列系统，部分功能可能需要调整"
                ;;
            *)
                warn "未经测试的操作系统: $ID，可能会遇到问题"
                ;;
        esac
    fi
    
    # 检查磁盘空间
    info "检查磁盘空间..."
    check_disk_space 2000 || error "磁盘空间不足，需要至少 2GB，安装中止。请清理磁盘后重试"
    
    # 检查内存 (cross-platform)
    local mem_total=0
    if command -v free &>/dev/null; then
        mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    elif [[ "$(uname)" == "Darwin" ]]; then
        mem_total=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 1073741824) / 1024 / 1024 ))
    fi
    
    if [[ $mem_total -lt 1024 ]]; then
        warn "系统内存不足 1GB (${mem_total}MB)，可能影响性能"
    elif [[ $mem_total -gt 0 ]]; then
        info "系统内存: ${mem_total}MB"
    fi
    
    # 安装依赖 (兼容不同发行版)
    info "安装必要依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl dnsutils cron ufw < /dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q curl bind-utils cronie firewalld < /dev/null 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl bind-utils cronie firewalld < /dev/null 2>/dev/null || true
    fi
    
    # 启用定时任务服务
    if systemctl is-active --quiet crond 2>/dev/null; then
        systemctl enable --now crond 2>/dev/null || true
    else
        systemctl enable --now cron 2>/dev/null || true
    fi
    
    # 配置防火墙
    info "配置防火墙规则..."
    if command -v ufw &>/dev/null; then
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=http 2>/dev/null || true
        firewall-cmd --permanent --add-service=https 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
    
    log "系统环境检查完成"
}

install_docker() {
    step "${ICON_GEAR} 检查 Docker 环境"
    if ! command -v docker &> /dev/null; then
        info "正在安装 Docker..."
        local docker_install_log=$(mktemp)
        curl -fsSL https://get.docker.com | sh > "$docker_install_log" 2>&1 &
        local docker_pid=$!
        spinner $docker_pid "安装 Docker 中..."
        if ! wait $docker_pid; then
            error "Docker 安装失败，请查看日志: $docker_install_log"
        fi
        rm -f "$docker_install_log"
        systemctl enable --now docker
        log "Docker 安装完成"
    else
        log "Docker 已安装 ($(docker --version | cut -d' ' -f3 | tr -d ','))"
    fi
    
    if ! docker compose version &> /dev/null; then
        info "安装 Docker Compose 插件..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq docker-compose-plugin
        elif command -v yum &>/dev/null; then
            yum install -y -q docker-compose-plugin 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y -q docker-compose-plugin 2>/dev/null || true
        fi
    fi
    log "Docker Compose 已就绪"
}

check_dns() {
    local domain=$1
    step "${ICON_GLOBE} 验证域名解析"
    
    info "获取服务器公网 IP..."
    local public_ip=$(curl -s -4 --connect-timeout 5 https://ifconfig.me || curl -s -4 --connect-timeout 5 http://icanhazip.com || echo "unknown")
    
    info "解析域名 $domain..."
    local resolved_ip=$(dig +short "$domain" A | tail -n1)
    
    echo -e "  ${DIM}├─ 服务器 IP: ${NC}${CYAN}$public_ip${NC}"
    echo -e "  ${DIM}└─ 域名解析: ${NC}${CYAN}$resolved_ip${NC}"
    
    if [[ "$resolved_ip" != "$public_ip" ]]; then
        warn "IP 地址不一致"
        echo -e "  ${DIM}   (如果您使用 Cloudflare 代理，这是正常的)${NC}"
        printf "${YELLOW}  是否继续？[y/N]: ${NC}"
        IFS= read -r confirm || confirm=""
        [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] && error "用户取消部署"
    fi
    log "域名解析验证通过"
}

# ======================== 用户交互 ========================
select_php_version() {
    step "${ICON_GEAR} 选择 PHP 版本"
    echo ""
    echo -e "  ${CYAN}1)${NC} PHP 7.4  ${DIM}(旧版本，兼容性好)${NC}"
    echo -e "  ${CYAN}2)${NC} PHP 8.0"
    echo -e "  ${CYAN}3)${NC} PHP 8.1"
    echo -e "  ${CYAN}4)${NC} PHP 8.2  ${GREEN}← 推荐${NC}"
    echo -e "  ${CYAN}5)${NC} PHP 8.3"
    echo -e "  ${CYAN}6)${NC} PHP 8.4  ${DIM}(最新版本)${NC}"
    echo -e "  ${CYAN}7)${NC} 自定义版本"
    echo ""
    printf "${GREEN}  请选择 [1-7] (默认 4): ${NC}"
    IFS= read -r choice || choice=""
    case "$choice" in
        1) PHP_VERSION="7.4" ;;
        2) PHP_VERSION="8.0" ;;
        3) PHP_VERSION="8.1" ;;
        4|"") PHP_VERSION="8.2" ;;
        5) PHP_VERSION="8.3" ;;
        6) PHP_VERSION="8.4" ;;
        7)
            printf "${GREEN}  请输入自定义版本号 (如 8.2): ${NC}"
            IFS= read -r custom_ver || custom_ver=""
            PHP_VERSION="${custom_ver:-8.2}"
            ;;
        *) PHP_VERSION="8.2" ;;
    esac
    log "已选择 PHP $PHP_VERSION"
}

select_mariadb_version() {
    step "${ICON_DATABASE} 选择 MariaDB 版本"
    echo ""
    echo -e "  ${CYAN}1)${NC} MariaDB 10.6  ${DIM}(LTS 长期支持)${NC}"
    echo -e "  ${CYAN}2)${NC} MariaDB 10.11 ${GREEN}← 推荐 (LTS)${NC}"
    echo -e "  ${CYAN}3)${NC} MariaDB 11.0"
    echo -e "  ${CYAN}4)${NC} MariaDB 11.2"
    echo -e "  ${CYAN}5)${NC} MariaDB 11.4  ${DIM}(最新稳定版)${NC}"
    echo -e "  ${CYAN}6)${NC} MySQL 8.0     ${DIM}(使用官方 MySQL)${NC}"
    echo -e "  ${CYAN}7)${NC} 自定义版本"
    echo ""
    printf "${GREEN}  请选择 [1-7] (默认 2): ${NC}"
    IFS= read -r choice || choice=""
    case "$choice" in
        1) MARIADB_VERSION="10.6" ;;
        2|"") MARIADB_VERSION="10.11" ;;
        3) MARIADB_VERSION="11.0" ;;
        4) MARIADB_VERSION="11.2" ;;
        5) MARIADB_VERSION="11.4" ;;
        6) MARIADB_VERSION="mysql:8.0" ;;
        7)
            printf "${GREEN}  请输入版本号 (如 10.11 或 mysql:8.0): ${NC}"
            IFS= read -r custom_ver || custom_ver=""
            MARIADB_VERSION="${custom_ver:-10.11}"
            ;;
        *) MARIADB_VERSION="10.11" ;;
    esac
    
    if [[ "$MARIADB_VERSION" == mysql:* ]]; then
        log "已选择 MySQL ${MARIADB_VERSION#mysql:}"
    else
        log "已选择 MariaDB $MARIADB_VERSION"
    fi
}

collect_domain_info() {
    step "${ICON_GLOBE} 配置域名信息"
    while true; do
        printf "${GREEN}  请输入主域名 (如 example.com): ${NC}"
        IFS= read -r DOMAIN || DOMAIN=""
        [[ -z "$DOMAIN" ]] && error "域名不能为空"
        
        # 验证域名格式
        if validate_domain "$DOMAIN"; then
            break
        else
            warn "域名格式不正确，请输入有效的域名 (如 example.com)"
        fi
    done
    
    echo ""
    echo -e "  ${DIM}添加子域名 (如 www, api, blog)，留空完成:${NC}"
    while true; do
        printf "${CYAN}  子域名: ${NC}"
        IFS= read -r sub || sub=""
        [[ -z "$sub" ]] && break
        
        # 验证子域名格式
        if validate_subdomain "$sub"; then
            SUBDOMAINS+=("$sub")
            echo -e "    ${GREEN}${ICON_OK}${NC} 已添加: ${sub}.${DOMAIN}"
        else
            warn "子域名格式不正确，请只使用字母、数字和连字符"
        fi
    done
    
    if [[ ${#SUBDOMAINS[@]} -eq 0 ]]; then
        SUBDOMAINS=("www")
    fi
    
    echo ""
    echo -e "  ${BOLD}域名配置摘要:${NC}"
    echo -e "    ${DIM}├─ 主域名: ${NC}${CYAN}$DOMAIN${NC}"
    for sub in "${SUBDOMAINS[@]}"; do
        echo -e "    ${DIM}├─ 子域名: ${NC}${CYAN}${sub}.${DOMAIN}${NC}"
    done
    echo ""
}

select_cert_type() {
    step "${ICON_LOCK} 选择证书类型"
    echo ""
    echo -e "  ${CYAN}1)${NC} 单域名证书 ${DIM}(HTTP-01 验证，简单快速)${NC}"
    echo -e "  ${CYAN}2)${NC} 通配符证书 ${DIM}(DNS-01 验证，需要 DNS API)${NC}"
    echo ""
    printf "${GREEN}  请选择 [1-2] (默认 1): ${NC}"
    IFS= read -r choice || choice=""
    
    case "$choice" in
        2) CERT_TYPE="wildcard"
           select_dns_provider
           ;;
        *) CERT_TYPE="single" ;;
    esac
}

select_dns_provider() {
    echo ""
    echo -e "  ${BOLD}选择 DNS 服务商:${NC}"
    echo -e "  ${CYAN}1)${NC} Cloudflare"
    echo -e "  ${CYAN}2)${NC} 阿里云 (Aliyun)"
    echo -e "  ${CYAN}3)${NC} DNSPod (腾讯云)"
    echo ""
    printf "${GREEN}  请选择 [1-3]: ${NC}"
    IFS= read -r provider_choice || provider_choice=""
    
    case "$provider_choice" in
        1) DNS_PROVIDER="cloudflare"
           printf "${GREEN}  请输入 Cloudflare API Token: ${NC}"
           IFS= read -r CF_TOKEN || CF_TOKEN=""
           if [[ -z "$CF_TOKEN" ]]; then
               error "API Token 不能为空"
           fi
           ;;
        2) DNS_PROVIDER="aliyun"
           printf "${GREEN}  请输入阿里云 AccessKey ID: ${NC}"
           IFS= read -r ALI_KEY || ALI_KEY=""
           if [[ -z "$ALI_KEY" ]]; then
               error "AccessKey ID 不能为空"
           fi
           printf "${GREEN}  请输入阿里云 AccessKey Secret: ${NC}"
           IFS= read -r ALI_SECRET || ALI_SECRET=""
           if [[ -z "$ALI_SECRET" ]]; then
               error "AccessKey Secret 不能为空"
           fi
           ;;
        3) DNS_PROVIDER="dnspod"
           printf "${GREEN}  请输入 DNSPod ID: ${NC}"
           IFS= read -r DP_ID || DP_ID=""
           if [[ -z "$DP_ID" ]]; then
               error "DNSPod ID 不能为空"
           fi
           printf "${GREEN}  请输入 DNSPod Token: ${NC}"
           IFS= read -r DP_TOKEN || DP_TOKEN=""
           if [[ -z "$DP_TOKEN" ]]; then
               error "DNSPod Token 不能为空"
           fi
           ;;
        *) error "无效选择" ;;
    esac
    return 0
}

select_nginx_type() {
    step "${ICON_GEAR} 选择 Nginx 版本"
    echo ""
    echo -e "  ${CYAN}1)${NC} 官方 Nginx + GeoIP2 ${GREEN}← 推荐${NC}"
    echo -e "     ${DIM}(自动构建，支持 GeoIP2 地理位置识别)${NC}"
    echo -e "  ${CYAN}2)${NC} LinuxServer Nginx"
    echo -e "     ${DIM}(预装 GeoIP2，更简单但镜像较大)${NC}"
    echo -e "  ${CYAN}3)${NC} 官方 Nginx 标准版"
    echo -e "     ${DIM}(无 GeoIP2，最小镜像)${NC}"
    echo ""
    printf "${GREEN}  请选择 [1-3] (默认 1): ${NC}"
    IFS= read -r nginx_choice || nginx_choice=""
    
    case "$nginx_choice" in
        2) NGINX_TYPE="linuxserver" ;;
        3) NGINX_TYPE="standard" ;;
        *) NGINX_TYPE="official" ;;
    esac
    
    case "$NGINX_TYPE" in
        official)    log "已选择: 官方 Nginx + GeoIP2 (需要构建)" ;;
        linuxserver) log "已选择: LinuxServer Nginx (预装 GeoIP2)" ;;
        standard)    log "已选择: 官方 Nginx 标准版 (无 GeoIP2)" ;;
    esac
}

ask_phpmyadmin() {
    echo ""
    printf "${GREEN}  是否安装 phpMyAdmin? [y/N]: ${NC}"
    IFS= read -r pma_choice || pma_choice=""
    if [[ "$pma_choice" =~ ^[Yy]$ ]]; then
        INSTALL_PHPMYADMIN="yes"
    fi
}

collect_credentials() {
    step "${ICON_DATABASE} 配置数据库"
    echo ""
    echo -e "  ${CYAN}1)${NC} 自动生成强密码 ${GREEN}← 推荐${NC}"
    echo -e "  ${CYAN}2)${NC} 手动输入密码"
    echo ""
    printf "${GREEN}  请选择 [1-2] (默认 1): ${NC}"
    IFS= read -r pwd_choice || pwd_choice="1"
    
    case "$pwd_choice" in
        2)
            # 手动密码会被写入 .env (同时被 bash source 和 docker compose 解析)，
            # 含空格/引号/$/#/反斜杠等会破坏解析甚至 source 时执行命令。限制为
            # 字母数字加一组对两种解析器都安全的符号，含其它字符则要求重输。
            while true; do
                printf "${GREEN}  请输入 MySQL root 密码 (允许 A-Z a-z 0-9 及 ._-+=@): ${NC}"
                IFS= read -r MYSQL_ROOT_PASS || MYSQL_ROOT_PASS=""
                echo ""
                if [[ -z "$MYSQL_ROOT_PASS" ]]; then
                    MYSQL_ROOT_PASS=$(generate_strong_password)
                    echo -e "  ${YELLOW}${ICON_WARN}${NC} 密码为空，已自动生成强密码"
                    break
                elif [[ "$MYSQL_ROOT_PASS" =~ ^[A-Za-z0-9._+=@-]+$ ]]; then
                    echo -e "  ${GREEN}${ICON_OK}${NC} 密码已设置"
                    break
                else
                    echo -e "  ${RED}${ICON_FAIL}${NC} 含不允许的字符，请仅使用 A-Z a-z 0-9 及 ._-+=@ 重试"
                fi
            done
            ;;
        *)
            MYSQL_ROOT_PASS=$(generate_strong_password)
            echo -e "  ${GREEN}${ICON_OK}${NC} 已生成安全密码"
            ;;
    esac
    
    # 确保密码已设置
    if [[ -z "$MYSQL_ROOT_PASS" ]]; then
        MYSQL_ROOT_PASS=$(generate_strong_password)
    fi
    
    # 生成 Redis 密码
    REDIS_PASSWORD=$(generate_strong_password 16)
    echo -e "  ${GREEN}${ICON_OK}${NC} 已生成 Redis 密码"
    
    log "数据库配置完成"
}

# ======================== 目录和文件生成 ========================
setup_directories() {
    step "${ICON_FOLDER} 创建目录结构"
    
    # Directory structure depends on nginx type
    local dirs=()
    
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        # linuxserver/nginx uses /config directory structure
        dirs=(
            "$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
            "$PROJECT_DIR/volumes/nginx/config/keys"
        )
    else
        # Official nginx uses /etc/nginx structure
        dirs=(
            "$PROJECT_DIR/volumes/nginx/conf.d"
            "$PROJECT_DIR/volumes/nginx/ssl"
            "$PROJECT_DIR/docker/nginx"
        )
    fi
    
    # Common directories
    dirs+=(
        "$PROJECT_DIR/volumes/php/www/$DOMAIN"
        "$PROJECT_DIR/volumes/php/logs"
        "$PROJECT_DIR/volumes/mysql/conf.d"
        "$PROJECT_DIR/volumes/mysql/data"
        "$PROJECT_DIR/volumes/redis"
        "$PROJECT_DIR/volumes/nginx/logs"
        "$PROJECT_DIR/volumes/fail2ban"
        "$PROJECT_DIR/certbot/conf"
        "$PROJECT_DIR/certbot/www"
        "$BACKUP_DIR"
    )
    
    local total=${#dirs[@]}
    local i=0
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        i=$((i + 1))
        progress_bar $i $total
    done
    echo ""
    
    # 复制脚本到部署目录
    local script_name=$(basename "$0")
    if [[ "$SCRIPT_DIR" != "$PROJECT_DIR" ]]; then
        cp "$0" "$PROJECT_DIR/deploy.sh"
        chmod +x "$PROJECT_DIR/deploy.sh"
        info "部署脚本已复制到: $PROJECT_DIR/deploy.sh"
    fi
    
    log "目录结构创建完成"
}

setup_php_dockerfile() {
    step "${ICON_GEAR} 创建 PHP Dockerfile"
    
    mkdir -p "$PROJECT_DIR/docker/php"
    
    cat > "$PROJECT_DIR/docker/php/Dockerfile" << 'EOFDOCKER'
ARG PHP_VERSION=8.2
FROM php:${PHP_VERSION}-fpm-alpine

# 时区 (中国标准时间)，需配合下方安装的 tzdata 包生效
ENV TZ=Asia/Shanghai

# 在单个 RUN 层中完成所有构建操作以最小化镜像体积
# 1. 安装运行时依赖 (永久保留)
# 2. 安装编译依赖 (临时，使用 --virtual 标记)
# 3. 编译 PHP 扩展
# 4. 清理所有编译依赖和缓存
RUN set -eux; \
    apk add --no-cache \
        curl \
        libcurl \
        libzip \
        libpng \
        libjpeg-turbo \
        freetype \
        libxml2 \
        oniguruma \
        icu-libs \
        fcgi \
        tzdata \
    ; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        curl-dev \
        libzip-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        libxml2-dev \
        oniguruma-dev \
        icu-dev \
        linux-headers \
    ; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j$(nproc) \
        mysqli pdo pdo_mysql curl zip mbstring xml gd intl opcache bcmath exif; \
    pecl install redis; \
    docker-php-ext-enable redis; \
    pecl clear-cache; \
    apk del --no-network .build-deps; \
    rm -rf /var/cache/apk/* /tmp/* /usr/src/* /root/.composer; \
    php -m | grep -qE "redis|opcache"

# 配置和健康检查 (合并为一层减少体积)
RUN mkdir -p /var/log/php && chown www-data:www-data /var/log/php \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && printf '#!/bin/sh\nSCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 2>/dev/null | grep -q pong\n' > /usr/local/bin/php-fpm-healthcheck \
    && chmod +x /usr/local/bin/php-fpm-healthcheck

COPY www.conf /usr/local/etc/php-fpm.d/www.conf
COPY custom.ini /usr/local/etc/php/conf.d/99-custom.ini
WORKDIR /var/www/html
EXPOSE 9000
CMD ["php-fpm"]
EOFDOCKER

    # 生成 PHP-FPM 配置文件 (使用动态参数)
    local pm_max_children=$(get_php_pm_max_children)
    local pm_start_servers=$(get_php_pm_start_servers)
    local pm_min_spare=$(get_php_pm_min_spare)
    local pm_max_spare=$(get_php_pm_max_spare)
    
    # Ensure pm_max_spare >= pm_start_servers (PHP-FPM requirement)
    if [[ $pm_max_spare -lt $pm_start_servers ]]; then
        pm_max_spare=$pm_start_servers
    fi
    
    cat > "$PROJECT_DIR/docker/php/www.conf" << EOFWWW
[www]
user = www-data
group = www-data
listen = 9000

; 动态进程管理 (基于服务器配置: ${SERVER_TIER})
pm = dynamic
pm.max_children = ${pm_max_children}
pm.start_servers = ${pm_start_servers}
pm.min_spare_servers = ${pm_min_spare}
pm.max_spare_servers = ${pm_max_spare}
pm.max_requests = 1000
pm.process_idle_timeout = 10s

; 内存保护: 单个请求超时强制回收，防止卡死请求持续占用内存
request_terminate_timeout = 300s

; 状态和健康检查
pm.status_path = /status
ping.path = /ping
ping.response = pong

; 慢日志
slowlog = /var/log/php/slow.log
request_slowlog_timeout = 5s

; 安全
security.limit_extensions = .php
EOFWWW

    log "PHP Dockerfile 创建完成 (PM: max_children=${pm_max_children})"
}

# 生成 Nginx Dockerfile (for official nginx with GeoIP2)
setup_nginx_dockerfile() {
    step "${ICON_GEAR} 创建 Nginx Dockerfile (GeoIP2 支持)"
    
    mkdir -p "$PROJECT_DIR/docker/nginx"
    
    cat > "$PROJECT_DIR/docker/nginx/Dockerfile" << 'EOFNGINXDOCKER'
# Multi-stage build for Nginx with GeoIP2 module
# 基础镜像 nginx:alpine 始终为最新稳定版；构建时自动探测其精确版本并下载
# 对应源码编译 GeoIP2 动态模块，无需手动指定版本号 —— 永远跟随最新 nginx。

# Stage 1: Build the GeoIP2 module against the exact nginx version in the base image
FROM nginx:alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    gcc \
    libc-dev \
    make \
    openssl-dev \
    pcre2-dev \
    zlib-dev \
    linux-headers \
    libxslt-dev \
    gd-dev \
    geoip-dev \
    libmaxminddb-dev \
    git

# 探测基础镜像的 nginx 版本 -> 下载完全匹配的源码 -> 编译 GeoIP2 模块。
# --with-compat 保证动态模块与运行镜像二进制兼容。
RUN set -eux; \
    NGINX_VERSION="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
    echo "Building GeoIP2 module for nginx ${NGINX_VERSION}"; \
    wget "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz; \
    tar -zxf nginx.tar.gz; \
    git clone --depth 1 https://github.com/leev/ngx_http_geoip2_module.git; \
    cd "nginx-${NGINX_VERSION}"; \
    ./configure --with-compat --add-dynamic-module=../ngx_http_geoip2_module; \
    make modules; \
    cp objs/ngx_http_geoip2_module.so /tmp/ngx_http_geoip2_module.so

# Stage 2: Final image (same nginx:alpine -> same version as the module was built for)
FROM nginx:alpine

# 时区 (中国标准时间)
ENV TZ=Asia/Shanghai

# Install runtime dependencies for GeoIP2 (含 tzdata 使时区生效)
RUN apk add --no-cache libmaxminddb tzdata \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

# Copy the compiled module from builder
COPY --from=builder /tmp/ngx_http_geoip2_module.so /usr/lib/nginx/modules/

# Create necessary directories
RUN mkdir -p /etc/nginx/conf.d /var/log/nginx /etc/nginx/geoip

# Set permissions
RUN chown -R nginx:nginx /var/log/nginx

EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
EOFNGINXDOCKER

    log "Nginx Dockerfile 创建完成 (支持 GeoIP2)"
}

# 生成优化的 Nginx 主配置
setup_nginx_main_config() {
    step "${ICON_GEAR} 创建 Nginx 主配置 (性能优化)"
    
    # 获取动态参数
    local worker_connections=$(get_nginx_worker_connections)
    local client_body_buffer=$(get_nginx_client_body_buffer)

    # Cloudflare 真实 IP 还原: 站点在 CF 后面时，$remote_addr 是 CF 节点 IP，
    # 会导致限流/日志/fail2ban 针对 CF 而非真实访客 (封 CF 节点 = 大批正常访客打不开)。
    # 用 real_ip + CF-Connecting-IP 把 $remote_addr 还原为真实客户端。
    # 始终开启，不再只限于 CF 通配符证书: 单域名证书 + 开 CF 代理同样需要。
    # 安全: set_real_ip_from 只信任来自 CF 网段的连接发来的 CF-Connecting-IP，
    # 直连服务器的客户端伪造这个头不会生效；没套 CF 时这些规则不会命中，无副作用。
    CF_REALIP_BLOCK=$'    # --- Cloudflare 真实客户端 IP 还原 ---\n'
    local _cidr
    for _cidr in $CF_IP_RANGES; do
        CF_REALIP_BLOCK+="    set_real_ip_from ${_cidr};"$'\n'
    done
    CF_REALIP_BLOCK+=$'    real_ip_header CF-Connecting-IP;\n    real_ip_recursive on;\n'

    # fail2ban 封禁名单: 宿主机文件 volumes/nginx/f2b-banned.conf (linuxserver 在 config/nginx/ 下)，
    # 必须先存在 (哪怕为空)，否则 nginx 启动时 include 找不到文件会直接报错
    local banlist_host
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        F2B_NGINX_BANLIST="/config/nginx/f2b-banned.conf"
        banlist_host="$PROJECT_DIR/volumes/nginx/config/nginx/f2b-banned.conf"
    else
        F2B_NGINX_BANLIST="/etc/nginx/f2b-banned.conf"
        banlist_host="$PROJECT_DIR/volumes/nginx/f2b-banned.conf"
    fi
    mkdir -p "$(dirname "$banlist_host")"
    [[ -f "$banlist_host" ]] || : > "$banlist_host"

    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        # linuxserver/nginx uses /config/nginx/ for configuration
        _create_linuxserver_nginx_config "$worker_connections" "$client_body_buffer"
    else
        # Official nginx or standard nginx uses /etc/nginx/
        _create_official_nginx_config "$worker_connections" "$client_body_buffer"
    fi
    
    local geoip_status="disabled"
    [[ "$NGINX_TYPE" != "standard" ]] && geoip_status="enabled"
    log "Nginx 主配置创建完成 (worker_connections=${worker_connections}, geoip2 ${geoip_status})"
}

# Helper function for linuxserver nginx config
_create_linuxserver_nginx_config() {
    local worker_connections=$1
    local client_body_buffer=$2
    
    cat > "$PROJECT_DIR/volumes/nginx/config/nginx/nginx.conf" << EOFNGINXMAIN
# linuxserver/nginx configuration
# GeoIP2 module for HTTP (pre-installed in linuxserver/nginx)
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
# Note: To enable stream (TCP/UDP) GeoIP2, uncomment the following two lines:
# load_module /usr/lib/nginx/modules/ngx_stream_module.so;
# load_module /usr/lib/nginx/modules/ngx_stream_geoip2_module.so;

user abc;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /config/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections ${worker_connections};
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 第二列固定写 "-"，不记 \$remote_user: 它来自客户端 Authorization 头，可塞入空格或伪造的
    # [时间戳]，让 fail2ban 的正则或时间解析失效，从而永远不被封禁
    log_format main '\$remote_addr - - [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';

    # 已封禁 IP 的请求不写日志 (见下方 geo \$f2b_banned)：既减少日志量，
    # 也避免被拦的请求又被 fail2ban 计数，导致封禁无限续期
    access_log /config/log/nginx/access.log main buffer=16k flush=2m if=\$f2b_log;

    # 性能优化
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/rss+xml application/atom+xml image/svg+xml;

    # 缓冲区优化 (基于服务器配置: ${SERVER_TIER})
    client_body_buffer_size ${client_body_buffer};
    client_header_buffer_size 1k;
    client_max_body_size 100M;
    large_client_header_buffers 4 8k;

    # 超时设置
    client_body_timeout 30;
    client_header_timeout 30;
    send_timeout 30;

${CF_REALIP_BLOCK}
    # fail2ban 封禁名单 (由 f2b_bridge.sh 每分钟同步)。按 \$remote_addr 匹配，
    # 已经过上面的真实 IP 还原，所以站点走 Cloudflare 代理时也能拦住真实访客。
    geo \$f2b_banned {
        default 0;
        include ${F2B_NGINX_BANLIST};
    }
    map \$f2b_banned \$f2b_log { 1 0; default 1; }

    # 限流配置 (防止 DDoS)
    limit_req_zone \$binary_remote_addr zone=req_limit:10m rate=20r/s;
    limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

    # WAF: 恶意 User-Agent 黑名单 (爬虫/采集 bot/扫描器)。命中 \$bad_bot=1，
    # 在站点 server 的 waf-guard.conf 片段里 return 444 (直接断连)。
    map \$http_user_agent \$bad_bot {
        default 0;
        "" 1;
        "~*(SemrushBot|AhrefsBot|MJ12bot|DotBot|PetalBot|Bytespider|GPTBot|ClaudeBot|CCBot|DataForSeoBot|BLEXBot|serpstatbot|ZoominfoBot|YisouSpider)" 1;
        # 中国采集/SEO/已停运搜索类爬虫 (不含百度/搜狗/360/神马 等正规搜索引擎，保留收录)
        "~*(EasouSpider|JikeSpider|EtaoSpider|YoudaoBot|MauiBot|EasouBot|YYSpider|LinkpadBot|Ezooms)" 1;
        # 只封扫描器。curl / wget / python-requests 等通用 HTTP 客户端不封:
        # 监控、接口调用、运维脚本都在用，封了会误伤，且 fail2ban 会把来源 IP 一并封掉
        "~*(masscan|nmap|nikto|sqlmap|zgrab)" 1;
    }

    # WAF: 敏感/扫描路径黑名单 (配置文件、版本控制、后台探测)。命中 \$bad_path=1。
    # 用 \$uri (已解码+规范化) 而非 \$request_uri (原始未解码)，否则 /%2egit 这类
    # 百分号编码可绕过字面正则。注意 \$uri 不含 query string，纯路径匹配正合适。
    map \$uri \$bad_path {
        default 0;
        "~*(\.env|\.git|\.svn|\.hg|/wp-login\.php|/xmlrpc\.php|/vendor/|/\.aws|/phpunit|/\.ssh|/config\.php\.bak|/\.DS_Store)" 1;
    }

    # 包含虚拟主机配置 (linuxserver/nginx uses site-confs)
    include /config/nginx/site-confs/*.conf;
}
EOFNGINXMAIN

    log "Nginx 主配置创建完成 (worker_connections=${worker_connections}, geoip2 enabled)"
}

# Helper function for official/standard nginx config
_create_official_nginx_config() {
    local worker_connections=$1
    local client_body_buffer=$2
    
    # Create main nginx.conf for official nginx
    local geoip_load=""
    if [[ "$NGINX_TYPE" == "official" ]]; then
        geoip_load="# GeoIP2 module (compiled with official nginx)
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
"
    fi
    
    cat > "$PROJECT_DIR/volumes/nginx/nginx.conf" << EOFNGINXMAIN
# Official Nginx configuration
${geoip_load}
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections ${worker_connections};
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 第二列固定写 "-"，不记 \$remote_user: 它来自客户端 Authorization 头，可塞入空格或伪造的
    # [时间戳]，让 fail2ban 的正则或时间解析失效，从而永远不被封禁
    log_format main '\$remote_addr - - [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';

    # 已封禁 IP 的请求不写日志 (见下方 geo \$f2b_banned)：既减少日志量，
    # 也避免被拦的请求又被 fail2ban 计数，导致封禁无限续期
    access_log /var/log/nginx/access.log main buffer=16k flush=2m if=\$f2b_log;

    # 性能优化
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/rss+xml application/atom+xml image/svg+xml;

    # 缓冲区优化 (基于服务器配置: ${SERVER_TIER})
    client_body_buffer_size ${client_body_buffer};
    client_header_buffer_size 1k;
    client_max_body_size 100M;
    large_client_header_buffers 4 8k;

    # 超时设置
    client_body_timeout 30;
    client_header_timeout 30;
    send_timeout 30;

${CF_REALIP_BLOCK}
    # fail2ban 封禁名单 (由 f2b_bridge.sh 每分钟同步)。按 \$remote_addr 匹配，
    # 已经过上面的真实 IP 还原，所以站点走 Cloudflare 代理时也能拦住真实访客。
    geo \$f2b_banned {
        default 0;
        include ${F2B_NGINX_BANLIST};
    }
    map \$f2b_banned \$f2b_log { 1 0; default 1; }

    # 限流配置 (防止 DDoS)
    limit_req_zone \$binary_remote_addr zone=req_limit:10m rate=20r/s;
    limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

    # WAF: 恶意 User-Agent 黑名单 (爬虫/采集 bot/扫描器)。命中 \$bad_bot=1，
    # 在站点 server 的 waf-guard.conf 片段里 return 444 (直接断连)。
    map \$http_user_agent \$bad_bot {
        default 0;
        "" 1;
        "~*(SemrushBot|AhrefsBot|MJ12bot|DotBot|PetalBot|Bytespider|GPTBot|ClaudeBot|CCBot|DataForSeoBot|BLEXBot|serpstatbot|ZoominfoBot|YisouSpider)" 1;
        # 中国采集/SEO/已停运搜索类爬虫 (不含百度/搜狗/360/神马 等正规搜索引擎，保留收录)
        "~*(EasouSpider|JikeSpider|EtaoSpider|YoudaoBot|MauiBot|EasouBot|YYSpider|LinkpadBot|Ezooms)" 1;
        # 只封扫描器。curl / wget / python-requests 等通用 HTTP 客户端不封:
        # 监控、接口调用、运维脚本都在用，封了会误伤，且 fail2ban 会把来源 IP 一并封掉
        "~*(masscan|nmap|nikto|sqlmap|zgrab)" 1;
    }

    # WAF: 敏感/扫描路径黑名单 (配置文件、版本控制、后台探测)。命中 \$bad_path=1。
    # 用 \$uri (已解码+规范化) 而非 \$request_uri (原始未解码)，否则 /%2egit 这类
    # 百分号编码可绕过字面正则。注意 \$uri 不含 query string，纯路径匹配正合适。
    map \$uri \$bad_path {
        default 0;
        "~*(\.env|\.git|\.svn|\.hg|/wp-login\.php|/xmlrpc\.php|/vendor/|/\.aws|/phpunit|/\.ssh|/config\.php\.bak|/\.DS_Store)" 1;
    }

    # 包含虚拟主机配置
    include /etc/nginx/conf.d/*.conf;
}
EOFNGINXMAIN
}

# ======================== WAF (Web 应用防护) ========================
# 生成可被站点 server 块 include 的 WAF 守卫片段。
# 之所以用片段 + include 而非写进 http{}: nginx 的 if / limit_req / limit_conn
# 这类指令只能出现在 server/location 上下文，不能放 http{}；用片段能让主站点和
# 所有子域名共用同一套规则，且 --setup-waf 升级旧环境时只需注入一行 include。
setup_waf_guard() {
    step "${ICON_LOCK} 创建 WAF 守卫规则"

    # 片段挂载到容器内固定路径: official/standard 为 /etc/nginx/waf-guard.conf;
    # linuxserver 的 nginx 同样 include /etc/nginx/ (site-confs 里用绝对路径引用)。
    local waf_file
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        waf_file="$PROJECT_DIR/volumes/nginx/config/nginx/waf-guard.conf"
    else
        waf_file="$PROJECT_DIR/volumes/nginx/waf-guard.conf"
    fi
    mkdir -p "$(dirname "$waf_file")"

    cat > "$waf_file" << 'EOFWAF'
# WAF 守卫片段 (由 deploy.sh 生成) —— 被各站点 server 块 include。
# $bad_bot / $bad_path 的 map 定义在主 nginx.conf 的 http{} 中。

# 0) fail2ban 已封禁的 IP -> 444。网站走 Cloudflare 时 iptables 拦不到真实访客，靠这一层兜住
if ($f2b_banned) { return 444; }

# 1) 恶意 UA / 扫描路径 -> 444 (不返回任何响应，直接断开连接，省带宽)
if ($bad_bot)  { return 444; }
if ($bad_path) { return 444; }

# 2) 请求限流: 平均 20r/s (zone 定义在 http{})，允许突发 50 个请求不延迟。
#    这个阈值能容忍正常访客并行加载 CSS/JS/图片，但挡住持续刷接口的 CC 攻击。
#    超出返回 429 (由 fail2ban 捕获累计封禁)。
limit_req  zone=req_limit burst=50 nodelay;
limit_req_status 429;

# 3) 单 IP 并发连接上限 (正常浏览器一般 <10，机器人并发抓取会超)
limit_conn conn_limit 30;
limit_conn_status 429;
EOFWAF

    log "WAF 守卫规则创建完成: $waf_file"
}

# 把 "include .../waf-guard.conf;" 幂等地注入已存在站点配置的每个 443 server 块。
# 用于 --setup-waf 升级旧部署 —— 不重写整段站点配置，只在 server { 后插一行。
inject_waf_include() {
    local nginx_conf_dir include_line
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
        include_line="    include /config/nginx/waf-guard.conf;"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
        include_line="    include /etc/nginx/waf-guard.conf;"
    fi

    [[ -d "$nginx_conf_dir" ]] || return 0

    local f count=0
    for f in "$nginx_conf_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        # 跳过已含 include 的文件 (幂等)
        grep -q "waf-guard.conf" "$f" 2>/dev/null && continue
        grep -q "listen 443" "$f" 2>/dev/null || continue
        # 只在 "listen 443" 那一行后插入一次 include —— 必落在 443 server 块内。
        # 不能用 sed /^server {/a：文件里常同时有 80 跳转块和 443 块，那样会插进
        # 每个 server 块，导致 waf-guard 的 limit_req 在 80 块重复 (nginx 报
        # "limit_req directive is duplicate")，且 80 跳转块本就无需 WAF。
        awk -v inc="$include_line" '
            !done && /listen/ && /443/ { print; print inc; done=1; next }
            { print }
        ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        count=$((count + 1))
    done
    [[ $count -gt 0 ]] && log "已为 $count 个站点配置注入 WAF include"
    return 0
}

# 生成 MySQL 优化配置
setup_mysql_config() {
    step "${ICON_GEAR} 创建 MySQL 优化配置"
    
    # 获取动态参数
    local innodb_buffer=$(get_mysql_innodb_buffer)
    local max_connections=$(get_mysql_max_connections)
    local table_cache=$(get_mysql_table_cache)
    local tmp_table=$(get_mysql_tmp_table)
    
    cat > "$PROJECT_DIR/volumes/mysql/conf.d/custom.cnf" << EOFMYSQL
[mysqld]
# 基本设置
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
default-storage-engine = InnoDB

# 时区: 使用 +08:00 偏移量 (中国标准时间)，无需加载时区表
# 保证 NOW()、时间戳字段等返回中国时间
default-time-zone = '+08:00'

# InnoDB 优化 (基于服务器配置: ${SERVER_TIER})
innodb_buffer_pool_size = ${innodb_buffer}
innodb_log_file_size = 64M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1

# 连接和缓存
max_connections = ${max_connections}
table_open_cache = ${table_cache}
thread_cache_size = 16

# 临时表
tmp_table_size = ${tmp_table}
max_heap_table_size = ${tmp_table}

# 日志
slow_query_log = 1
slow_query_log_file = /var/lib/mysql/slow.log
long_query_time = 2

# 安全设置
local_infile = 0
symbolic-links = 0
skip-name-resolve

[client]
default-character-set = utf8mb4
EOFMYSQL

    log "MySQL 优化配置创建完成 (buffer_pool=${innodb_buffer}, max_conn=${max_connections})"
}

# 生成 PHP 优化配置
setup_php_ini_config() {
    step "${ICON_GEAR} 创建 PHP 优化配置"
    
    mkdir -p "$PROJECT_DIR/docker/php"
    
    # 获取动态参数
    local memory_limit=$(get_php_memory_limit)
    local opcache_memory=$(get_php_opcache_memory)
    
    cat > "$PROJECT_DIR/docker/php/custom.ini" << EOFPHP
; 错误处理
display_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT

; 上传和内存 (基于服务器配置: ${SERVER_TIER})
upload_max_filesize = 100M
post_max_size = 100M
memory_limit = ${memory_limit}
max_execution_time = 300
max_input_time = 300
max_input_vars = 5000

; OPcache 优化
opcache.enable = 1
opcache.memory_consumption = ${opcache_memory}
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 2
opcache.fast_shutdown = 1
opcache.enable_cli = 0
opcache.validate_timestamps = 1

; Session 安全
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1

; 安全设置
expose_php = Off
allow_url_fopen = On
allow_url_include = Off

; 时区
date.timezone = Asia/Shanghai
EOFPHP

    log "PHP 优化配置创建完成 (memory_limit=${memory_limit}, opcache=${opcache_memory}MB)"
}

# 获取宿主机 IP 地址 (用于 Docker 容器访问宿主机服务)
get_host_ip() {
    local host_ip=""
    
    # 方法 1: 使用 docker0 网桥 IP (Linux)
    if command -v ip &>/dev/null; then
        host_ip=$(ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi
    
    # 方法 2: 使用默认网关 (通用)
    if [[ -z "$host_ip" ]]; then
        host_ip=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1) || true
    fi
    
    # 方法 3: 尝试获取主机的第一个非 lo 接口 IP
    if [[ -z "$host_ip" ]]; then
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    
    # 备用: 使用标准 Docker 桥接网络网关
    if [[ -z "$host_ip" ]]; then
        host_ip="172.17.0.1"
    fi
    
    echo "$host_ip"
}

# Helper function to generate nginx service section for docker-compose.yml
_generate_docker_compose_nginx() {
    case "$NGINX_TYPE" in
        official)
            # Official nginx with GeoIP2 - build from Dockerfile
            # 镜像在构建时自动跟随最新 nginx:alpine，无需版本 build arg
            cat << 'EOFNGINXSVC'
  nginx:
    build:
      context: ./docker/nginx
    image: lnmp-nginx-geoip2:latest
    # 本地构建镜像，不在任何仓库；强制 compose 构建而非拉取，
    # 避免 "pull access denied for lnmp-nginx-geoip2" 错误
    pull_policy: build
    container_name: ${PROJECT_NAME}_nginx
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./volumes/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./volumes/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./volumes/nginx/ssl:/etc/nginx/ssl:ro
      - ./volumes/nginx/waf-guard.conf:/etc/nginx/waf-guard.conf:ro
      # fail2ban 封禁名单 (f2b_bridge.sh 每分钟同步)，nginx 层按真实 IP 拦截
      - ./volumes/nginx/f2b-banned.conf:/etc/nginx/f2b-banned.conf:ro
      - ./volumes/php/www:/var/www/html:ro
      # fail2ban 面板静态文件: nginx 的 try_files/index 需在本容器内看到它
      - ./fail2ban-panel:/var/www/html/_f2bapp:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
      # 把 access/error 日志落到宿主机，供宿主机上的 fail2ban 读取
      - ./volumes/nginx/logs:/var/log/nginx
    depends_on:
      - php
    networks:
      - default
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOFNGINXSVC
            ;;
        linuxserver)
            # LinuxServer nginx - pre-installed GeoIP2
            cat << 'EOFNGINXSVC'
  nginx:
    image: linuxserver/nginx:latest
    container_name: ${PROJECT_NAME}_nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
    volumes:
      - ./volumes/nginx/config:/config
      - ./volumes/php/www:/var/www/html:ro
      # fail2ban 面板静态文件: nginx 的 try_files/index 需在本容器内看到它
      - ./fail2ban-panel:/var/www/html/_f2bapp:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
    depends_on:
      - php
    networks:
      - default
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOFNGINXSVC
            ;;
        standard)
            # Standard official nginx - no GeoIP2
            cat << 'EOFNGINXSVC'
  nginx:
    image: nginx:alpine
    container_name: ${PROJECT_NAME}_nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./volumes/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./volumes/nginx/conf.d:/etc/nginx/conf.d:ro
      - ./volumes/nginx/ssl:/etc/nginx/ssl:ro
      - ./volumes/nginx/waf-guard.conf:/etc/nginx/waf-guard.conf:ro
      # fail2ban 封禁名单 (f2b_bridge.sh 每分钟同步)，nginx 层按真实 IP 拦截
      - ./volumes/nginx/f2b-banned.conf:/etc/nginx/f2b-banned.conf:ro
      - ./volumes/php/www:/var/www/html:ro
      # fail2ban 面板静态文件: nginx 的 try_files/index 需在本容器内看到它
      - ./fail2ban-panel:/var/www/html/_f2bapp:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
      # 把 access/error 日志落到宿主机，供宿主机上的 fail2ban 读取
      - ./volumes/nginx/logs:/var/log/nginx
      # 标准 nginx:alpine 无 tzdata，挂载宿主机时区文件使日志时间为中国时间
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      - php
    networks:
      - default
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOFNGINXSVC
            ;;
    esac
}


setup_docker_compose() {
    step "${ICON_GEAR} 生成 Docker Compose 配置"
    
    local phpmyadmin_section=""
    if [[ "$INSTALL_PHPMYADMIN" == "yes" ]]; then
        phpmyadmin_section="
  phpmyadmin:
    image: phpmyadmin/phpmyadmin:latest
    container_name: \${PROJECT_NAME}_phpmyadmin
    restart: unless-stopped
    ports:
      - \"8080:80\"
    environment:
      - TZ=Asia/Shanghai
      - PMA_HOST=mysql
      - PMA_PORT=3306
      - UPLOAD_LIMIT=100M
    depends_on:
      - mysql
    networks:
      - default
    logging:
      driver: json-file
      options:
        max-size: \"10m\"
        max-file: \"3\""
    fi

    # Generate nginx service based on NGINX_TYPE
    local nginx_service
    nginx_service=$(_generate_docker_compose_nginx)

    # Create docker-compose.yml
    cat > "$PROJECT_DIR/docker-compose.yml" << EOFDC
services:
${nginx_service}

  php:
    build:
      context: ./docker/php
      args:
        PHP_VERSION: \${PHP_VERSION}
    image: lnmp-php:\${PHP_VERSION}
    container_name: \${PROJECT_NAME}_php
    restart: unless-stopped
    volumes:
      - ./volumes/php/www:/var/www/html
      - ./volumes/php/logs:/var/log/php
      # fail2ban 共享目录: 面板读 banned.txt、写 *-queue (队列隔离，见 f2b_bridge.sh)
      - ./volumes/fail2ban:/var/f2b
      # fail2ban 面板代码 (独立项目整棵树只读挂载；public/lib/config 保持同父目录)
      - ./fail2ban-panel:/var/www/html/_f2bapp:ro
    environment:
      - TZ=Asia/Shanghai
      - MYSQL_HOST=mysql
      - MYSQL_DATABASE=\${MYSQL_DB}
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASS}
      - REDIS_HOST=redis
      - REDIS_PASSWORD=\${REDIS_PASSWORD}
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - default
    healthcheck:
      test: ["CMD-SHELL", "php-fpm-healthcheck || kill -0 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  mysql:
    image: \${MARIADB_IMAGE}
    container_name: \${PROJECT_NAME}_mysql
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=\${MYSQL_DB}
    volumes:
      - ./volumes/mysql/data:/var/lib/mysql
      - ./volumes/mysql/conf.d:/etc/mysql/conf.d:ro
    networks:
      - default
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -uroot -p\$\$MYSQL_ROOT_PASSWORD 2>/dev/null || mariadb-admin ping -h localhost -uroot -p\$\$MYSQL_ROOT_PASSWORD 2>/dev/null || healthcheck.sh --connect 2>/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: redis:alpine
    container_name: \${PROJECT_NAME}_redis
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory \${REDIS_MAXMEMORY} --maxmemory-policy allkeys-lru --requirepass \${REDIS_PASSWORD}
    volumes:
      - ./volumes/redis:/data
      # redis:alpine 无 tzdata，挂载宿主机时区文件使日志时间为中国时间
      - /etc/localtime:/etc/localtime:ro
    networks:
      - default
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  certbot:
    image: certbot/certbot
    container_name: \${PROJECT_NAME}_certbot
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
      - /etc/localtime:/etc/localtime:ro
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do sleep 6h & wait; done'"
    networks:
      - default
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
${phpmyadmin_section}
networks:
  default:
    name: ${PROJECT_NAME}_net
    driver: bridge
EOFDC

    # 生成 .env 文件
    cat > "$PROJECT_DIR/.env" << EOFENV
PROJECT_NAME=$PROJECT_NAME
PHP_VERSION=$PHP_VERSION
MARIADB_VERSION=$MARIADB_VERSION
MARIADB_IMAGE=$(get_mariadb_image)
MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS
MYSQL_DB=$MYSQL_DB
DOMAIN=$DOMAIN
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_MAXMEMORY=$(get_redis_maxmemory)
BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS
NGINX_TYPE=$NGINX_TYPE
INSTALL_PHPMYADMIN=$INSTALL_PHPMYADMIN
CERT_TYPE=$CERT_TYPE
DNS_PROVIDER=$DNS_PROVIDER
SUBDOMAINS_LIST="${SUBDOMAINS[*]}"
EOFENV
    # 安全优化: 设置 .env 文件权限为仅 root 可读
    chmod 600 "$PROJECT_DIR/.env"

    log "Docker Compose 配置生成完成"
}

setup_nginx_initial() {
    step "${ICON_GEAR} 配置 Nginx (初始化)"
    
    # Determine config directory based on NGINX_TYPE
    local nginx_conf_dir
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
    fi
    
    # Ensure directory exists
    mkdir -p "$nginx_conf_dir"
    
    # HTTP 重定向配置
    cat > "$nginx_conf_dir/00-http-redirect.conf" << 'EOFNGINX'
server {
    listen 80 default_server;
    # 同时作为 IPv6 默认 server：容器内 localhost 常解析为 ::1，
    # 若此处不监听 [::]:80，健康检查/重定向请求会落到其它带 listen [::]:80
    # 的站点 server 而被 301 到 https，导致探测失败。
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # 健康检查专用端点: 纯 HTTP 返回 200, 不跳转 https。
    # 避免容器健康检查的 busybox wget (默认不支持 SSL) 跟随 301 到 https 而失败。
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
EOFNGINX
    log "Nginx 初始配置完成 (目录: $nginx_conf_dir)"
}

setup_nginx_final() {
    step "${ICON_GEAR} 配置 Nginx (HTTPS)"
    
    local ssl_cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    local config_index=1
    
    # Determine config directory based on NGINX_TYPE
    local nginx_conf_dir waf_include
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
        waf_include="    include /config/nginx/waf-guard.conf;"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
        waf_include="    include /etc/nginx/waf-guard.conf;"
    fi

    # Ensure directory exists
    mkdir -p "$nginx_conf_dir"

    # 主域名配置
    cat > "$nginx_conf_dir/0${config_index}-${DOMAIN}.conf" << EOFMAIN
server {
    listen 443 ssl;
    # HTTP/3 (QUIC, UDP 443)。reuseport 全局只能有一处，放在主域名这唯一必然存在的 server 块
    listen 443 quic reuseport;
    http2 on;
    http3 on;
    server_name $DOMAIN;
    root /var/www/html/$DOMAIN;
    index index.php index.html index.htm;

    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    # 告知浏览器可升级到 HTTP/3
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

${waf_include}

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}
EOFMAIN
    config_index=$((config_index + 1))

    # 子域名配置
    for sub in "${SUBDOMAINS[@]}"; do
        local sub_dir="$PROJECT_DIR/volumes/php/www/${sub}.${DOMAIN}"
        mkdir -p "$sub_dir"
        
        cat > "$nginx_conf_dir/0${config_index}-${sub}.conf" << EOFSUB
server {
    listen 443 ssl;
    listen 443 quic;
    http2 on;
    http3 on;
    server_name ${sub}.${DOMAIN};
    root /var/www/html/${sub}.${DOMAIN};
    index index.php index.html index.htm;

    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;

${waf_include}

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}
EOFSUB
        config_index=$((config_index + 1))
        
        # 创建默认欢迎页 (仅当站点目录还没有首页时；--cert 重签证书也会走这里，不能覆盖用户网站)
        if [[ ! -e "$sub_dir/index.html" && ! -e "$sub_dir/index.php" ]]; then
        cat > "$sub_dir/index.html" << EOFHTML
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>${sub}.${DOMAIN}</title>
<style>body{font-family:system-ui;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;text-align:center}</style>
</head><body><div><h1>${ICON_ROCKET} ${sub}.${DOMAIN}</h1><p>LNMP Stack Ready!</p></div></body></html>
EOFHTML
        fi
    done

    # 站点配置被重写后，重新注入 fail2ban 面板入口 (面板已安装时)
    local panel_inc_ct panel_inc_host
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        panel_inc_host="$PROJECT_DIR/volumes/nginx/config/nginx/f2b-panel.inc"; panel_inc_ct="/config/nginx/f2b-panel.inc"
    else
        panel_inc_host="$PROJECT_DIR/volumes/nginx/ssl/f2b-panel.inc";          panel_inc_ct="/etc/nginx/ssl/f2b-panel.inc"
    fi
    [[ -f "$panel_inc_host" ]] && _inject_panel_include "$panel_inc_ct"
    
    log "Nginx HTTPS 配置完成 (共 $config_index 个配置文件)"
}

setup_index_page() {
    step "${ICON_GEAR} 创建 PHP 欢迎页"
    
    # 确保目录存在
    local web_dir="$PROJECT_DIR/volumes/php/www/$DOMAIN"
    mkdir -p "$web_dir"

    # 已有首页就不覆盖 (重装、续装时用户可能已经上传了网站)
    if [[ -e "$web_dir/index.php" || -e "$web_dir/index.html" ]]; then
        log "网站首页已存在，保留不覆盖: $web_dir"
        return 0
    fi

    cat > "$web_dir/index.php" << 'EOFPHP'
<?php
$redis_status = "未连接";
try {
    $redis = new Redis();
    if ($redis->connect('redis', 6379)) {
        $redis_pass = getenv('REDIS_PASSWORD');
        if ($redis_pass) {
            $redis->auth($redis_pass);
        }
        $redis->set('test_key', 'Hello Redis!');
        $redis_status = "连接成功: " . $redis->get('test_key');
    }
} catch (Exception $e) {
    $redis_status = "错误: " . $e->getMessage();
}

$mysql_status = "未连接";
try {
    $pdo = new PDO("mysql:host=mysql;dbname=" . getenv('MYSQL_DATABASE'), 'root', getenv('MYSQL_ROOT_PASSWORD'));
    $mysql_status = "连接成功";
} catch (PDOException $e) {
    $mysql_status = "错误: " . $e->getMessage();
}
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LNMP Stack</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; display: flex; justify-content: center; align-items: center; }
        .container { background: rgba(255,255,255,0.95); padding: 40px; border-radius: 20px; box-shadow: 0 20px 60px rgba(0,0,0,0.3); max-width: 600px; width: 90%; }
        h1 { color: #333; margin-bottom: 30px; text-align: center; }
        .status { background: #f8f9fa; padding: 20px; border-radius: 10px; margin: 15px 0; }
        .status h3 { color: #495057; margin-bottom: 10px; }
        .ok { color: #28a745; } .err { color: #dc3545; }
        .info { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #dee2e6; }
        .footer { text-align: center; margin-top: 30px; color: #6c757d; font-size: 14px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 LNMP Stack</h1>
        <div class="status">
            <h3>📊 系统状态</h3>
            <div class="info"><span>PHP 版本</span><span class="ok"><?= phpversion() ?></span></div>
            <div class="info"><span>MySQL</span><span class="<?= strpos($mysql_status, '成功') !== false ? 'ok' : 'err' ?>"><?= $mysql_status ?></span></div>
            <div class="info"><span>Redis</span><span class="<?= strpos($redis_status, '成功') !== false ? 'ok' : 'err' ?>"><?= $redis_status ?></span></div>
            <div class="info"><span>服务器</span><span class="ok"><?= $_SERVER['SERVER_SOFTWARE'] ?? 'Nginx' ?></span></div>
        </div>
        <div class="footer">部署时间: <?= date('Y-m-d H:i:s') ?></div>
    </div>
</body>
</html>
EOFPHP

    # 验证文件创建成功
    if [[ -f "$web_dir/index.php" ]]; then
        log "PHP 欢迎页创建完成: $web_dir/index.php"
    else
        warn "无法创建 index.php 文件"
    fi
}

# ======================== SSL 证书 ========================
obtain_ssl_certificate() {
    step "${ICON_LOCK} 申请 SSL 证书"
    
    local domains="-d $DOMAIN"
    for sub in "${SUBDOMAINS[@]}"; do
        domains+=" -d ${sub}.${DOMAIN}"
    done

    if [[ "$CERT_TYPE" == "wildcard" ]]; then
        # For wildcard certificates, we need to pass domains as separate quoted arguments
        # to avoid shell glob expansion issues with the * character
        local wildcard_domain="*.$DOMAIN"
        
        case "$DNS_PROVIDER" in
            cloudflare)
                mkdir -p "$PROJECT_DIR/certbot/conf"
                echo "dns_cloudflare_api_token = $CF_TOKEN" > "$PROJECT_DIR/certbot/conf/cloudflare.ini"
                chmod 600 "$PROJECT_DIR/certbot/conf/cloudflare.ini"
                
                info "使用 Cloudflare DNS 验证申请通配符证书..."
                info "申请域名: $DOMAIN 和 $wildcard_domain"
                # Disable glob expansion and use quoted variables
                set -f
                docker run --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" \
                    certbot/dns-cloudflare certonly --dns-cloudflare \
                    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
                    --dns-cloudflare-propagation-seconds 30 \
                    -d "$DOMAIN" -d "$wildcard_domain" \
                    --email "admin@$DOMAIN" --agree-tos --non-interactive \
                    || { set +f; show_cert_retry_hint; return 1; }
                set +f
                ;;
            aliyun)
                mkdir -p "$PROJECT_DIR/certbot/conf"
                # 阿里云 DNS 需要使用第三方插件，这里提供手动 DNS 验证作为备选
                warn "阿里云 DNS 验证需要安装第三方插件"
                info "建议使用手动 DNS 验证或切换到 Cloudflare"
                echo ""
                echo -e "  ${CYAN}1)${NC} 使用手动 DNS 验证 (需要手动添加 TXT 记录)"
                echo -e "  ${CYAN}2)${NC} 取消并切换 DNS 服务商"
                printf "${GREEN}  请选择 [1-2]: ${NC}"
                IFS= read -r ali_choice || ali_choice=""
                
                if [[ "$ali_choice" == "1" ]]; then
                    info "申请域名: $DOMAIN 和 $wildcard_domain"
                    set -f
                    docker run -it --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" \
                        certbot/certbot certonly --manual --preferred-challenges dns \
                        -d "$DOMAIN" -d "$wildcard_domain" --email "admin@$DOMAIN" --agree-tos \
                        || { set +f; show_cert_retry_hint; return 1; }
                    set +f
                else
                    return 1
                fi
                ;;
            dnspod)
                mkdir -p "$PROJECT_DIR/certbot/conf"
                # DNSPod 同样需要第三方插件
                warn "DNSPod DNS 验证需要安装第三方插件"
                info "建议使用手动 DNS 验证或切换到 Cloudflare"
                echo ""
                echo -e "  ${CYAN}1)${NC} 使用手动 DNS 验证 (需要手动添加 TXT 记录)"
                echo -e "  ${CYAN}2)${NC} 取消并切换 DNS 服务商"
                printf "${GREEN}  请选择 [1-2]: ${NC}"
                IFS= read -r dp_choice || dp_choice=""
                
                if [[ "$dp_choice" == "1" ]]; then
                    info "申请域名: $DOMAIN 和 $wildcard_domain"
                    set -f
                    docker run -it --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" \
                        certbot/certbot certonly --manual --preferred-challenges dns \
                        -d "$DOMAIN" -d "$wildcard_domain" --email "admin@$DOMAIN" --agree-tos \
                        || { set +f; show_cert_retry_hint; return 1; }
                    set +f
                else
                    return 1
                fi
                ;;
        esac
    else
        # 单域名证书使用 HTTP-01 验证
        info "启动 Nginx 进行 HTTP-01 验证..."
        # 官方 Nginx 使用本地构建的 lnmp-nginx-geoip2 镜像 (不在任何仓库)，
        # 必须用 --build 让 compose 先构建，否则会误当作可拉取镜像而报
        # "pull access denied ... repository does not exist"
        docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d --build nginx
        
        # 等待 Nginx 启动完成
        local wait_count=0
        local max_wait=30
        while [[ $wait_count -lt $max_wait ]]; do
            if docker compose -f "$PROJECT_DIR/docker-compose.yml" ps nginx 2>/dev/null | grep -q "Up"; then
                break
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        # 检查 Nginx 是否启动成功
        if ! docker compose -f "$PROJECT_DIR/docker-compose.yml" ps nginx | grep -q "Up"; then
            warn "Nginx 启动失败，尝试查看日志..."
            docker compose -f "$PROJECT_DIR/docker-compose.yml" logs nginx
            return 1
        fi
        
        # Get the actual network name from docker compose
        local network_name=""
        # Wait a moment for network to be created
        sleep 2
        network_name=$(docker network ls --filter "name=${PROJECT_NAME}" --format '{{.Name}}' | grep -E '_default$|_net$' | head -1) || true
        if [[ -z "$network_name" ]]; then
            # Fallback: try to get network from running container
            network_name=$(docker inspect "${PROJECT_NAME}_nginx" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1) || true
        fi
        if [[ -z "$network_name" ]]; then
            network_name="${PROJECT_NAME}_default"
        fi
        
        info "申请单域名证书..."
        docker run --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" \
            -v "$PROJECT_DIR/certbot/www:/var/www/certbot" \
            --network "$network_name" \
            certbot/certbot certonly --webroot -w /var/www/certbot \
            $domains --email "admin@$DOMAIN" --agree-tos --non-interactive \
            || { show_cert_retry_hint; return 1; }
    fi

    if [[ ! -f "$PROJECT_DIR/certbot/conf/live/$DOMAIN/fullchain.pem" ]]; then
        show_cert_retry_hint
        return 1
    fi
    log "SSL 证书申请成功"
}

setup_cert_renewal() {
    step "${ICON_CLOCK} 配置证书自动续期"
    
    cat > "$PROJECT_DIR/renew-cert.sh" << 'EOFRENEW'
#!/bin/bash
set -e
cd "$(dirname "$0")"
LOG_FILE="./cert-renewal.log"

echo "[$(date)] 开始检查证书续期..." >> "$LOG_FILE"

# 尝试续期证书
# 用 certbot/dns-cloudflare 镜像: 通配符证书是用 Cloudflare 插件申请的，普通 certbot 镜像没有这个插件，
# 续期必然失败、90 天后证书过期。该镜像就是 certbot + 插件，单域名 (webroot) 证书同样能续。
if docker run --rm -v "$PWD/certbot/conf:/etc/letsencrypt" -v "$PWD/certbot/www:/var/www/certbot" \
        certbot/dns-cloudflare renew --quiet 2>> "$LOG_FILE"; then
    echo "[$(date)] 证书续期检查完成" >> "$LOG_FILE"
    # 只有续期成功才重载 Nginx
    if docker compose exec -T nginx nginx -t 2>> "$LOG_FILE"; then
        docker compose exec -T nginx nginx -s reload
        echo "[$(date)] Nginx 配置已重载" >> "$LOG_FILE"
    else
        echo "[$(date)] 错误: Nginx 配置测试失败，跳过重载" >> "$LOG_FILE"
    fi
else
    echo "[$(date)] 证书续期检查失败" >> "$LOG_FILE"
    exit 1
fi
EOFRENEW
    chmod +x "$PROJECT_DIR/renew-cert.sh"
    
    # 添加到 crontab (每天凌晨 3 点)
    local cron_job="0 3 * * * $PROJECT_DIR/renew-cert.sh >> $PROJECT_DIR/cert-renewal.log 2>&1"
    local temp_cron=$(mktemp)
    
    # 获取现有 crontab，忽略错误
    crontab -l > "$temp_cron" 2>/dev/null || true
    
    # 检查任务是否已存在
    if ! grep -q "$PROJECT_DIR/renew-cert.sh" "$temp_cron" 2>/dev/null; then
        echo "$cron_job" >> "$temp_cron"
        if crontab "$temp_cron" 2>/dev/null; then
            log "证书自动续期已配置 (每天凌晨 3 点检查)"
        else
            warn "无法添加证书续期 crontab 任务，请手动添加: $cron_job"
        fi
    else
        log "证书续期任务已存在于 crontab 中"
    fi

    rm -f "$temp_cron"
}

# ======================== 日志大小控制 ========================
# nginx 日志落在宿主机 bind mount 上，扫描流量大时一天就能涨到上百 MB，
# 拖慢 fail2ban 扫描并占满磁盘。系统 logrotate 每天才跑一次，压不住这种增速，
# 所以用每 5 分钟一次的 cron: 单个日志超过上限就原地截断，只留末尾一小段。
setup_log_rotate() {
    local script="$PROJECT_DIR/log_rotate.sh"
    local log_dir; log_dir=$(dirname "$(get_nginx_access_log)")

    cat > "$script" << EOFROTATE
#!/bin/bash
# 由 deploy.sh 生成: 日志超过 MAX_BYTES 时轮转 —— 改名为 .1 (覆盖上一份)，再让 nginx 重新打开日志。
# 不用原地截断: 截断后 fail2ban 会从头重读保留下来的部分，同一批请求被计数两次，封禁阈值被打折。
# 改名后 fail2ban 发现文件换了 (inode 变化)，会从新的空文件开始读。磁盘上最多约 2 × 10M。
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
MAX_BYTES=\$((10 * 1024 * 1024))   # 单个日志上限 10M
rotated=0
for f in "${log_dir}"/*.log; do
    [[ -f "\$f" && ! -L "\$f" ]] || continue
    size=\$(stat -c%s "\$f" 2>/dev/null || echo 0)
    if (( size > MAX_BYTES )); then
        # 改名后立即建一个空文件: 万一 reopen 失败，fail2ban 重启时 logpath 仍存在，不会整体起不来
        mv -f "\$f" "\$f.1" && : > "\$f" && rotated=1
    fi
done
if [[ \$rotated -eq 1 ]]; then
    # reopen: nginx 关闭旧文件句柄、按原路径新建日志，不中断请求
    (cd "\$SCRIPT_DIR" && docker compose exec -T nginx nginx -s reopen) >/dev/null 2>&1 \\
        || (cd "\$SCRIPT_DIR" && docker compose restart nginx) >/dev/null 2>&1 || true
fi
EOFROTATE
    chmod +x "$script"

    local cron_job="*/5 * * * * $script >/dev/null 2>&1"
    local temp_cron; temp_cron=$(mktemp)
    crontab -l > "$temp_cron" 2>/dev/null || true
    if ! grep -q "$script" "$temp_cron" 2>/dev/null; then
        echo "$cron_job" >> "$temp_cron"
        crontab "$temp_cron" 2>/dev/null && log "日志大小控制已配置 (每 5 分钟检查，单个日志上限 10M)" \
            || warn "无法添加日志控制 crontab，请手动添加: $cron_job"
    else
        log "日志大小控制任务已存在于 crontab 中"
    fi
    rm -f "$temp_cron"
}

# ======================== 备份功能 ========================
setup_backup() {
    step "${ICON_FOLDER} 配置自动备份"
    
    # 备份脚本需要从 .env 文件读取密码
    cat > "$BACKUP_SCRIPT" << 'EOFBACKUP'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

# 加载环境变量
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
fi

# 检查密码是否已设置
if [[ -z "$MYSQL_ROOT_PASS" ]]; then
    echo "[$(date)] 错误: MYSQL_ROOT_PASS 未设置，备份中止"
    exit 1
fi

# 备份文件含全部数据库内容，只允许 root 读
umask 077
MYSQL_CT="${PROJECT_NAME:-lnmp}_mysql"

# 备份数据库 (兼容 MariaDB 和 MySQL)
# MariaDB 10.5+ 使用 mariadb-dump (11.x 起已没有 mysqldump)，旧版本和 MySQL 使用 mysqldump。
# 必须经 sh -c 探测: command 是 shell 内建命令，直接 docker exec command 永远失败
DUMP_CMD="mysqldump"
if docker exec "$MYSQL_CT" sh -c 'command -v mariadb-dump' >/dev/null 2>&1; then
    DUMP_CMD="mariadb-dump"
fi

# 通过 MYSQL_PWD 环境变量传密码，避免暴露在宿主机进程列表 (ps/docker top)。
# 「-e MYSQL_PWD」不带值 = 从当前环境继承；写成 -e MYSQL_PWD=xxx 密码会出现在 docker 命令行里
# 先写 .partial，导出成功且内容完整才改名，避免失败时留下一个看似正常的残缺备份
DB_OUT="$BACKUP_DIR/db_$DATE.sql"
if MYSQL_PWD="$MYSQL_ROOT_PASS" docker exec -e MYSQL_PWD "$MYSQL_CT" $DUMP_CMD -uroot --all-databases \
        --single-transaction --routines --events > "$DB_OUT.partial" 2>"$BACKUP_DIR/.dump_err" \
   && tail -n 3 "$DB_OUT.partial" | grep -q 'Dump completed'; then
    mv -f "$DB_OUT.partial" "$DB_OUT"
    echo "[$(date)] 数据库备份成功: db_$DATE.sql (使用 $DUMP_CMD)"
else
    rm -f "$DB_OUT.partial"
    echo "[$(date)] 数据库备份失败: $(tail -n 2 "$BACKUP_DIR/.dump_err" 2>/dev/null | tr '\n' ' ')"
fi
rm -f "$BACKUP_DIR/.dump_err"

# 备份网站文件
if tar -czf "$BACKUP_DIR/www_$DATE.tar.gz" -C "$SCRIPT_DIR/volumes/php" www 2>/dev/null; then
    echo "[$(date)] 网站文件备份成功: www_$DATE.tar.gz"
else
    echo "[$(date)] 网站文件备份失败"
fi

# 保留最近 BACKUP_RETENTION_DAYS 天的备份 (默认 3 天)
RETENTION=${BACKUP_RETENTION_DAYS:-3}
find "$BACKUP_DIR" -name "*.sql" -mtime +$RETENTION -delete 2>/dev/null || true
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION -delete 2>/dev/null || true

# ---- 推送到云盘 (rclone copy 走一次性 Docker 容器，可选) ----
# 用 docker run --rm 起一个一次性 rclone 容器，复用用户已有的 rclone.conf 做 copy：
#   - rclone copy 会阻塞到上传完成并校验，真正确认到了云端 (不像挂载点异步上传无法确认)。
#   - 不碰用户现有的长期 rclone 容器，也不要求宿主机装 rclone 命令。
# 所有参数都在 .rclone-backup.env 里，可手动编辑定制 (不进 .env，--reconfig 不会冲掉)。
BACKUP_LOG="$SCRIPT_DIR/backup.log"
if [[ -f "$SCRIPT_DIR/.rclone-backup.env" ]]; then
    source "$SCRIPT_DIR/.rclone-backup.env"
    # 必填项齐全且 docker 可用才推送
    if [[ -n "${RCLONE_REMOTE:-}" && -n "${RCLONE_CONFIG_DIR:-}" ]] && command -v docker >/dev/null 2>&1; then
        RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone}"
        RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/config/rclone.conf}"
        # 一次性容器: 只读挂载用户的 rclone 配置目录和本地 backups 目录
        rclone_run() {
            docker run --rm \
                -v "$RCLONE_CONFIG_DIR:/config:ro" \
                -v "$BACKUP_DIR:/data:ro" \
                "$RCLONE_IMAGE" --config "$RCLONE_CONFIG_FILE" "$@"
        }
        # 删除用的容器 (不挂 /data，纯远端操作)
        rclone_run_remote() {
            docker run --rm \
                -v "$RCLONE_CONFIG_DIR:/config:ro" \
                "$RCLONE_IMAGE" --config "$RCLONE_CONFIG_FILE" "$@"
        }
        # 只推送本次刚生成且完整的文件 (带 $DATE 时间戳)；上一步失败未生成的文件被跳过
        pushed=0
        for f in "$DB_OUT" "$BACKUP_DIR/www_$DATE.tar.gz"; do
            [[ -f "$f" ]] || continue
            if rclone_run copy "/data/$(basename "$f")" "$RCLONE_REMOTE/" --no-traverse 2>>"$BACKUP_LOG"; then
                echo "[$(date)] 已推送到云盘: $(basename "$f")"; pushed=1
            else
                echo "[$(date)] 云盘推送失败: $(basename "$f")"
            fi
        done
        # 先传新再删旧: 只有本次至少成功推送一个文件，才清理云端旧备份 ——
        # 这样任意时刻云端至少有一份完整备份，坏备份/半截传输也不会覆盖掉好备份。
        # 保留刚传上去的 *_$DATE.*，删掉云端其它所有文件 (不含本次时间戳的即旧备份)。
        if [[ $pushed -eq 1 && "${CLOUD_KEEP_LATEST_ONLY:-1}" == "1" ]]; then
            rclone_run_remote lsf "$RCLONE_REMOTE/" 2>/dev/null | grep -vF "_$DATE." \
                | while IFS= read -r old; do
                    [[ -n "$old" ]] || continue
                    rclone_run_remote deletefile "$RCLONE_REMOTE/$old" 2>>"$BACKUP_LOG" \
                        && echo "[$(date)] 已删除云端旧备份: $old"
                  done
        fi
    elif [[ -n "${RCLONE_REMOTE:-}" ]]; then
        echo "[$(date)] 已配置云盘但 docker 不可用或配置不全，跳过推送"
    fi
fi

# 清理超过 10MB 的日志
LOG_FILE="$SCRIPT_DIR/backup.log"
if [[ -f "$LOG_FILE" ]]; then
    # 跨平台获取文件大小
    file_size=0
    if [[ "$(uname)" == "Darwin" ]]; then
        file_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    else
        file_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    fi
    if [[ $file_size -gt 10485760 ]]; then
        tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        echo "[$(date)] 日志文件已截断"
    fi
fi

echo "[$(date)] 备份任务完成"
EOFBACKUP
    chmod +x "$BACKUP_SCRIPT"
    
    # 添加到 crontab (每天凌晨 2 点)
    local cron_job="0 2 * * * $BACKUP_SCRIPT >> $PROJECT_DIR/backup.log 2>&1"
    local temp_cron=$(mktemp)
    
    # 获取现有 crontab，忽略错误（可能没有现有的 crontab）
    crontab -l > "$temp_cron" 2>/dev/null || true
    
    # 检查任务是否已存在
    if ! grep -q "$BACKUP_SCRIPT" "$temp_cron" 2>/dev/null; then
        echo "$cron_job" >> "$temp_cron"
        if crontab "$temp_cron" 2>/dev/null; then
            log "自动备份已配置 (每天凌晨 2 点)"
        else
            warn "无法添加 crontab 任务，请手动添加: $cron_job"
        fi
    else
        log "备份任务已存在于 crontab 中"
    fi
    
    rm -f "$temp_cron"
}

do_backup_now() {
    step "${ICON_FOLDER} 执行备份"
    if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        error "备份脚本不存在，请先运行完整安装"
    fi
    bash "$BACKUP_SCRIPT"
    log "备份完成，文件保存在 $BACKUP_DIR"
}

# 配置"备份到云盘": 用一次性 Docker 容器 (rclone/rclone 或用户自定义镜像) 把本地备份
# copy 到云端，复用用户已有的 rclone.conf。配置写进独立的 .rclone-backup.env
# (不进 .env，--reconfig 重写 .env 时不会被冲掉；该文件可手动编辑定制所有参数)。
RCLONE_BACKUP_ENV="$PROJECT_DIR/.rclone-backup.env"
cmd_setup_cloud_backup() {
    [[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行"
    show_banner
    step "${ICON_FOLDER} 配置备份到云盘 (rclone via Docker)"
    [[ -f "$PROJECT_DIR/.env" ]] || error "未找到 $PROJECT_DIR/.env，请先完成初始安装"
    command -v docker >/dev/null 2>&1 || error "未检测到 docker"

    echo -e "  ${DIM}通过一次性 Docker 容器运行 rclone，复用你已有的 rclone 配置 (rclone.conf) 推送备份。${NC}"
    echo -e "  ${DIM}不需要在宿主机单独安装 rclone，也不碰你现有的 rclone 容器。${NC}"
    echo ""

    # 1) rclone 镜像 (默认官方；用户可填自己的镜像)
    echo -e "  ${DIM}用哪个 rclone 镜像? 回车用官方 ${CYAN}rclone/rclone${NC}${DIM}，或填你自己的镜像名。${NC}"
    printf "${GREEN}  rclone 镜像 [rclone/rclone]: ${NC}"
    local rimage; IFS= read -r rimage || rimage=""
    rimage="${rimage:-rclone/rclone}"

    # 2) rclone 配置目录 (宿主机) —— 手动输入，不做自动探测:
    #    自动探测会把真实路径当默认值回显到终端，录屏/截图会泄漏个人目录结构，故要求手动输入。
    echo ""
    echo -e "  ${DIM}rclone 配置目录: 宿主机上含 rclone.conf 的目录 (绝对路径)。${NC}"
    echo -e "  ${DIM}如果你用 Docker 跑 rclone，就是挂到容器 /config 的那个宿主机目录。${NC}"
    local cfg_dir; printf "${GREEN}  配置目录: ${NC}"; IFS= read -r cfg_dir || cfg_dir=""
    [[ -n "$cfg_dir" ]] || error "配置目录不能为空"
    [[ "$cfg_dir" = /* ]] || error "请用绝对路径 (以 / 开头)"
    [[ -d "$cfg_dir" ]] || error "目录不存在: $cfg_dir"

    # 3) 确定 conf 文件 (容器内路径 = /config/<相对位置>)，就地校验存在
    local conf_rel="rclone.conf"
    if [[ ! -f "$cfg_dir/rclone.conf" ]]; then
        local found; found=$(find "$cfg_dir" -maxdepth 2 -name '*.conf' 2>/dev/null | head -1) || true
        [[ -n "$found" ]] || error "在 $cfg_dir 下未找到 rclone.conf 或任何 .conf 文件，请确认路径"
        conf_rel="${found#$cfg_dir/}"
        info "使用配置文件: $conf_rel"
    fi
    local conf_in_ct="/config/$conf_rel"

    # 4) 校验: 用镜像读该配置，确认至少能列出一个 remote (配置有效)
    info "校验配置 (用 $rimage 读取 $conf_rel)..."
    local avail
    avail=$(docker run --rm -v "$cfg_dir:/config:ro" "$rimage" --config "$conf_in_ct" listremotes 2>/tmp/rclone-test.err) || true
    if [[ -z "$avail" ]]; then
        warn "未能从该配置读出任何 remote，镜像/路径/配置可能有误:"
        cat /tmp/rclone-test.err 2>/dev/null | head -8
        rm -f /tmp/rclone-test.err
        error "请检查: 镜像 $rimage、配置目录 $cfg_dir、conf 文件 $conf_rel"
    fi
    rm -f /tmp/rclone-test.err
    echo -e "  ${BOLD}该配置可用的 remote:${NC}"
    local rr; while IFS= read -r rr; do [[ -n "$rr" ]] && echo -e "    ${CYAN}${rr}${NC}"; done <<< "$avail"

    # 5) 备份目标 remote:路径，校验 remote 名在上面列表里，再测连通
    echo ""
    echo -e "  ${DIM}备份目标，格式 ${BOLD}remote名:路径${NC}${DIM}，例如 ${CYAN}myremote:lnmp-backup${NC}"
    printf "${GREEN}  备份目标: ${NC}"
    local target; IFS= read -r target || target=""
    [[ -z "$target" ]] && error "目标不能为空"
    [[ "$target" == *:* ]] || error "格式错误，应为 remote名:路径 (如 myremote:lnmp-backup)"
    local rname="${target%%:*}:"
    grep -qxF "$rname" <<< "$avail" || error "remote「$rname」不在该配置里 (见上面列表)"

    info "测试连通性 (在 $target 建目录)..."
    if ! docker run --rm -v "$cfg_dir:/config:ro" "$rimage" --config "$conf_in_ct" mkdir "$target" 2>/tmp/rclone-test.err; then
        warn "连通性测试失败:"
        cat /tmp/rclone-test.err 2>/dev/null | head -8
        rm -f /tmp/rclone-test.err
        error "请检查网络与云端授权"
    fi
    rm -f /tmp/rclone-test.err
    log "云端目标可访问: $target"

    # 6) 写配置文件 (600)
    cat > "$RCLONE_BACKUP_ENV" << EOFRCLONE
# 备份到云盘配置 (由 deploy.sh --setup-cloud-backup 生成，可手动编辑)
# backup_task.sh 每次本地备份成功后读取此文件，用一次性 docker 容器跑 rclone copy 推送。
# 本文件独立于 .env，--reconfig 不会覆盖它。删除本文件即关闭云盘推送。
RCLONE_IMAGE="$rimage"
RCLONE_CONFIG_DIR="$cfg_dir"
RCLONE_CONFIG_FILE="$conf_in_ct"
RCLONE_REMOTE="$target"
# 1 = 云端只保留最新一份 (先传新再删旧); 0 = 不自动删除云端旧备份
CLOUD_KEEP_LATEST_ONLY=1
EOFRCLONE
    chmod 600 "$RCLONE_BACKUP_ENV"
    log "云盘备份配置已保存: $RCLONE_BACKUP_ENV"

    # 7) 确保 backup_task.sh 是最新版 (含云端推送段)
    setup_backup

    # 8) 可选: 立即试跑一次
    echo ""
    printf "${GREEN}  现在立即执行一次备份并推送到云盘以验证? [Y/n]: ${NC}"
    local run_now; IFS= read -r run_now || run_now=""
    if [[ ! "$run_now" =~ ^[Nn]$ ]]; then
        if [[ -f "$BACKUP_SCRIPT" ]]; then
            cd "$PROJECT_DIR" || error "无法进入项目目录"
            bash "$BACKUP_SCRIPT"
            echo ""
            info "云端当前文件:"
            docker run --rm -v "$cfg_dir:/config:ro" "$rimage" --config "$conf_in_ct" lsf "$target/" 2>/dev/null | sed 's/^/    /' || true
        fi
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ${ICON_OK} ${BOLD}云盘备份已配置！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${DIM}每天凌晨 2 点的自动备份成功后会推送到 ${CYAN}${target}${NC}${DIM}，云端只保留最新一份。${NC}"
    echo -e "  ${DIM}本地 backups/ 仍按 BACKUP_RETENTION_DAYS 天保留，是额外一层。${NC}"
    echo -e "  ${DIM}所有参数都在 ${CYAN}${RCLONE_BACKUP_ENV}${NC}${DIM} 里，可手动编辑; 删除该文件即关闭推送。${NC}"
    echo ""
}

# ======================== fail2ban + 网页解封面板 ========================
# 返回宿主机上 nginx access.log 的实际路径 (随 NGINX_TYPE 变化)
get_nginx_access_log() {
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        echo "$PROJECT_DIR/volumes/nginx/config/log/nginx/access.log"
    else
        echo "$PROJECT_DIR/volumes/nginx/logs/access.log"
    fi
}

# 安装 fail2ban (宿主机)
install_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        log "fail2ban 已安装 ($(fail2ban-client --version 2>/dev/null | head -1))"
    else
        info "安装 fail2ban..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq fail2ban < /dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q epel-release < /dev/null 2>/dev/null || true
            yum install -y -q fail2ban < /dev/null 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y -q fail2ban < /dev/null 2>/dev/null || true
        else
            warn "未识别的包管理器，请手动安装 fail2ban"
            return 1
        fi
        log "fail2ban 安装完成"
    fi
    # iptables + ipset 是封禁动作的前提 (ipset 让几千个封禁 IP 只占一条规则)
    local pkg missing=()
    for pkg in iptables ipset; do command -v "$pkg" &>/dev/null || missing+=("$pkg"); done
    if [[ ${#missing[@]} -gt 0 ]]; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq "${missing[@]}" < /dev/null 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${missing[@]}" < /dev/null 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}" < /dev/null 2>/dev/null || true
        fi
    fi
    command -v ipset &>/dev/null || warn "未能安装 ipset，网站封禁动作将无法执行，请手动安装: apt-get install ipset"
    systemctl enable --now fail2ban 2>/dev/null || true
    return 0
}

# 生成 fail2ban 过滤器 / 动作 / jail 配置
setup_fail2ban_config() {
    step "${ICON_LOCK} 配置 fail2ban (DOCKER-USER 链封禁)"

    local access_log; access_log=$(get_nginx_access_log)

    # 确保日志文件存在：fail2ban 启动时若 logpath 不存在，会导致整个 jail
    # 加载失败、服务 failed（表现为 "jail lnmp-nginx 不存在"）。nginx 首次
    # 产生访问前该文件可能尚未生成，这里预先创建占位文件兜底。
    mkdir -p "$(dirname "$access_log")"
    [[ -f "$access_log" ]] || touch "$access_log"

    # --- 过滤器: 匹配本脚本自定义 log_format main 中状态码为 444/429/403 的行 ---
    # 格式: <ip> - <user> [time] "METHOD uri proto" status ...
    cat > /etc/fail2ban/filter.d/lnmp-nginx.conf << 'EOFF2BFILTER'
[Definition]
# 匹配被 WAF 拦截(444)、限流(429)或拒绝(403)的请求行，源 IP = <HOST>
# 注意: fail2ban 匹配前会把时间戳从行里删掉 (剩 "[]")，故用 \[[^\]]*\] 而非 \[[^\]]+\]，
# 否则任何行都匹配不上 (表现为有拦截统计但 Total failed 始终为 0)。
# 第二条只看请求路径 (不含 ? 后的参数)，避免 "?q=.env" 这类正常搜索被误计；
# \.git 后要求 / 或结尾，避免误中 /.github/ 之类的正常路径
failregex = ^<HOST> - \S+ \[[^\]]*\] "(GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH|CONNECT)[^"]*" (444|429|403)
            ^<HOST> - \S+ \[[^\]]*\] "[A-Z]+ [^ ?"]*(/\.env|/\.git(/|[ ?])|/wp-login\.php|/xmlrpc\.php|/vendor/)
ignoreregex =
# 显式指定 nginx $time_local 的时间格式 (如 29/Oct/2026:10:00:00 +0800)。
# 不指定时 fail2ban 要对每一行逐个尝试几十种时间模板，日志量大时 CPU 占用很高。
datepattern = %%d/%%b/%%Y:%%H:%%M:%%S %%z
EOFF2BFILTER

    # --- 封禁动作: 把 IP DROP 进 DOCKER-USER 链 (Docker 发布端口绕过 INPUT) ---
    # Docker 发布的 80/443 流量走 nat/PREROUTING -> DOCKER 链，不经 INPUT；
    # DOCKER-USER 是 Docker 官方保证在 DOCKER 之前处理、且用户可控的链。
    # 用 ipset 保存封禁 IP: 不管封多少个，DOCKER-USER 里都只有一条匹配规则 (哈希查找)，
    # 每 IP 一条 iptables 规则时，几千条规则会让每个进入容器的包逐条比对，CPU 开销很大。
    # 只封 IPv4；timeout 0 = 永不过期，由 fail2ban 自己按 bantime 解封。
    cat > /etc/fail2ban/action.d/docker-user.conf << 'EOFF2BACTION'
[Definition]
actionstart = ipset -exist create f2b-lnmp hash:ip timeout 0 maxelem 262144
              iptables -N DOCKER-USER 2>/dev/null || true
              iptables -C DOCKER-USER -m set --match-set f2b-lnmp src -j DROP 2>/dev/null || iptables -I DOCKER-USER -m set --match-set f2b-lnmp src -j DROP
# 停止时只清空集合，不删规则和集合: Docker 可能正在引用，删除会报错
actionstop  = ipset flush f2b-lnmp 2>/dev/null || true
# 每次封禁前检查规则还在；被 firewalld reload / iptables-restore 等清掉时，fail2ban 会自动重跑 actionstart
actioncheck = iptables -C DOCKER-USER -m set --match-set f2b-lnmp src -j DROP
# IPv6 地址不封 (不加入集合，也不会报错)。
# 注意: 值里不能出现「空格+分号」，fail2ban 解析配置时会把 " ;" 后面当注释截掉 (所以不用 case ... ;;)
actionban   = echo "<ip>" | grep -q : || ipset -exist add f2b-lnmp <ip>
actionunban = echo "<ip>" | grep -q : || ipset -exist del f2b-lnmp <ip>

[Init]
EOFF2BACTION

    # --- 白名单: 放在 [DEFAULT]，对 lnmp-nginx 与 sshd 都生效 ---
    # 默认白名单: 本机 + 局域网/内网网段，始终保证在列，不被误封。
    #   10/8 172.16/12 192.168/16  RFC1918 局域网 (含 Docker 网桥 172.17-31.x)
    #   100.64/10                  运营商 CGNAT / Tailscale 等组网
    #   fc00::/7 fe80::/10         IPv6 内网 / 链路本地
    # 再合并已有 ignoreip (用户手动加的 IP、面板加白的 IP)，--reconfig 不会冲掉它们。
    local jail_file="/etc/fail2ban/jail.d/lnmp.local"
    local lan_ignore="127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fc00::/7 fe80::/10"
    local old_ignore ignoreip
    old_ignore=$(grep -m1 -E '^ignoreip[[:space:]]*=' "$jail_file" 2>/dev/null \
        | sed -E 's/^ignoreip[[:space:]]*=[[:space:]]*//') || true
    # Cloudflare 节点也加入白名单: 万一真实 IP 还原没生效 (日志里记的是 CF 节点)，
    # fail2ban 也不会把 CF 节点封掉，避免大批正常访客被误封
    # ::/0 = 全部 IPv6 地址: 只封 IPv4，IPv6 一律不封 (网站与 SSH 都适用)
    ignoreip=$(printf '%s\n' $lan_ignore $CF_IP_RANGES ::/0 $old_ignore | awk 'NF && !seen[$0]++' | paste -sd' ' -)

    # --- SSH 爆破封禁: 探测 sshd 日志来源与端口 ---
    # sshd 是宿主机服务，封在 INPUT 链 (iptables-multiport)，与网站的 DOCKER-USER 链分开。
    # 日志来源必须可用，否则 jail 加载失败会拖垮整个 fail2ban，探测不到就跳过。
    local sshd_section="" ssh_desc=""
    if command -v sshd &>/dev/null || [[ -f /etc/ssh/sshd_config ]]; then
        local ssh_port
        ssh_port=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | paste -sd, -) || true
        [[ -z "$ssh_port" ]] && { ssh_port=$(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | paste -sd, -) || true; }
        [[ -z "$ssh_port" ]] && ssh_port="22"

        local ssh_src=""
        if [[ -f /var/log/auth.log ]]; then
            ssh_src="logpath   = /var/log/auth.log"          # Debian 11 / Ubuntu
        elif [[ -f /var/log/secure ]]; then
            ssh_src="logpath   = /var/log/secure"            # CentOS / RHEL
        else
            # Debian 12 默认无 rsyslog，日志只在 journald；systemd 后端需要 python3-systemd
            if ! python3 -c 'import systemd.journal' &>/dev/null && command -v apt-get &>/dev/null; then
                apt-get install -y -qq python3-systemd < /dev/null &>/dev/null || true
            fi
            if python3 -c 'import systemd.journal' &>/dev/null; then
                ssh_src="backend   = systemd"
            fi
        fi

        if [[ -n "$ssh_src" ]]; then
            sshd_section="[sshd]
enabled   = true
port      = ${ssh_port}
${ssh_src}
banaction = iptables-multiport
# 10 分钟内认证失败 5 次 -> 封禁 24 小时
maxretry  = 5
findtime  = 600
bantime   = 86400"
            ssh_desc="SSH 端口 ${ssh_port}"
        else
            warn "未找到可用的 SSH 日志来源 (auth.log / secure / journald)，跳过 SSH 爆破封禁"
            # 显式关闭: Debian 自带配置默认启用 sshd jail，找不到日志会让整个 fail2ban 起不来
            sshd_section="[sshd]
enabled   = false"
        fi
    fi

    mkdir -p /etc/fail2ban/jail.d
    cat > "$jail_file" << EOFF2BJAIL
[DEFAULT]
# 全局白名单: 本机/内网 + 你的固定出口 IP (空格分隔追加)，对网站和 SSH 都生效。
# 网页面板的「加白名单」也写到这一行。
ignoreip  = ${ignoreip}

[lnmp-nginx]
enabled   = true
filter    = lnmp-nginx
logpath   = ${access_log}
banaction = docker-user
# 封禁强度: 1 小时内命中 5 次 -> 封禁 24 小时。
# 分布式扫描会把请求分散到大量 IP，单 IP 每分钟只有一两次，
# 用 "60 秒 10 次" 永远凑不满；只统计 444/429/403 与敏感路径，正常访客几乎不会触发。
maxretry  = 5
findtime  = 3600
bantime   = 86400

${sshd_section}
EOFF2BJAIL

    log "fail2ban 配置完成 (网站日志: ${access_log}${ssh_desc:+；已启用 ${ssh_desc} 爆破封禁})"

    # 重载 fail2ban 使配置生效
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
    else
        systemctl restart fail2ban 2>/dev/null || true
    fi
}

# 本地 GeoIP 国家库: DB-IP "IP to Country Lite" (免费、无需注册，CC BY 4.0，按月更新)。
# 面板的国家/地区列由桥接脚本用 mmdblookup 离线查这个库，不调用任何在线 IP 查询接口。
setup_geoip_db() {
    local geo_dir="$PROJECT_DIR/volumes/geoip"
    local updater="$PROJECT_DIR/geoip_update.sh"
    mkdir -p "$geo_dir"

    # mmdblookup 在 Debian/Ubuntu 的 mmdb-bin 包、RHEL 系的 libmaxminddb 包里
    if ! command -v mmdblookup &>/dev/null; then
        info "安装 mmdblookup (本地 GeoIP 查询工具)..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq mmdb-bin < /dev/null &>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf install -y -q libmaxminddb < /dev/null &>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y -q libmaxminddb < /dev/null &>/dev/null || true
        fi
    fi

    cat > "$updater" << 'EOFGEOUPD'
#!/bin/bash
# 由 deploy.sh 生成: 下载/更新 DB-IP 国家库 (每月 1 日前后发布新版)。
# 下载失败时保留旧库，不影响面板。
GEO_DIR="$(cd "$(dirname "$0")" && pwd)/volumes/geoip"
DB="$GEO_DIR/dbip-country-lite.mmdb"
mkdir -p "$GEO_DIR"
tmp=$(mktemp "$GEO_DIR/.dl.XXXXXX")
ok=0
# 当月文件有时月初还没发布，失败则回退上月
for ym in "$(date +%Y-%m)" "$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m 2>/dev/null)"; do
    [[ -n "$ym" ]] || continue
    if curl -fsSL -m 120 "https://download.db-ip.com/free/dbip-country-lite-${ym}.mmdb.gz" -o "$tmp.gz" \
        && gunzip -c "$tmp.gz" > "$tmp" && [[ -s "$tmp" ]]; then
        ok=1; break
    fi
done
if [[ $ok -eq 1 ]] && { ! command -v mmdblookup &>/dev/null || mmdblookup --file "$tmp" --ip 8.8.8.8 country iso_code &>/dev/null; }; then
    mv -f "$tmp" "$DB"; chmod 644 "$DB"
    echo "[$(date '+%F %T')] GeoIP 库已更新"
else
    rm -f "$tmp"
    echo "[$(date '+%F %T')] GeoIP 库下载失败，保留旧库"
fi
rm -f "$tmp.gz"
EOFGEOUPD
    chmod +x "$updater"

    if [[ ! -s "$geo_dir/dbip-country-lite.mmdb" ]]; then
        info "下载 GeoIP 国家库 (DB-IP Lite, 约 7MB)..."
        bash "$updater" || true
    fi
    if [[ -s "$geo_dir/dbip-country-lite.mmdb" ]]; then
        log "GeoIP 国家库就绪: $geo_dir/dbip-country-lite.mmdb"
    else
        warn "GeoIP 库下载失败，面板国家列将显示「未知」；稍后可手动运行: $updater"
    fi
    command -v mmdblookup &>/dev/null || warn "未能安装 mmdblookup，面板国家列将显示「未知」"

    # 每月 3 日凌晨 4 点更新一次，幂等
    local cron_job="0 4 3 * * $updater >/dev/null 2>&1"
    local temp_cron; temp_cron=$(mktemp)
    crontab -l > "$temp_cron" 2>/dev/null || true
    if ! grep -q "$updater" "$temp_cron" 2>/dev/null; then
        echo "$cron_job" >> "$temp_cron"
        crontab "$temp_cron" 2>/dev/null || warn "无法添加 GeoIP 更新 crontab，请手动添加: $cron_job"
    fi
    rm -f "$temp_cron"
}

# 生成宿主机 cron 桥接脚本 (队列隔离的核心)
# PHP 面板永远不直接调用 fail2ban-client，只与 /var/f2b 下的文件交互；
# 本脚本以 root 每分钟运行，负责导出封禁列表 + 校验消费解封队列。
setup_f2b_bridge() {
    local bridge="$PROJECT_DIR/f2b_bridge.sh"
    local f2b_dir="$PROJECT_DIR/volumes/fail2ban"
    mkdir -p "$f2b_dir"
    setup_geoip_db
    # 目录需让 PHP 容器内 www-data 写 unban-queue (bind mount 按 UID 映射)。
    # php:*-fpm-alpine 的 www-data 为 UID/GID 82 —— 把目录归属给它并用 0770，
    # 既满足面板写入，又避免 0777 让宿主机上任意本地用户都能投递队列、
    # 借 root 桥接脚本封禁/加白任意 IP。root (cron 跑桥接) 本就不受权限限制。
    chown 82:82 "$f2b_dir" 2>/dev/null || true
    chmod 770 "$f2b_dir" 2>/dev/null || true

    # 桥接脚本需要知道 nginx access.log 的宿主机路径 (随 NGINX_TYPE)，安装时实填
    local access_log; access_log=$(get_nginx_access_log)
    local nginx_banlist
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_banlist="$PROJECT_DIR/volumes/nginx/config/nginx/f2b-banned.conf"
    else
        nginx_banlist="$PROJECT_DIR/volumes/nginx/f2b-banned.conf"
    fi

    cat > "$bridge" << EOFBRIDGE
#!/bin/bash
# fail2ban <-> 网页面板 桥接脚本 (以 root 运行，每分钟一次)
# 安全模型: 面板(PHP)只写队列文件，真正的 fail2ban 操作只在此 root 脚本里发生，
# 且执行前严格校验是合法 IPv4/IPv6，杜绝命令注入。
set -eu
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
F2B_DIR="\$SCRIPT_DIR/volumes/fail2ban"
JAIL="lnmp-nginx"
JAIL_LOCAL="/etc/fail2ban/jail.d/lnmp.local"
ACCESS_LOG="${access_log}"
NGINX_BANLIST="${nginx_banlist}"
BANNED_FILE="\$F2B_DIR/banned.txt"
UNBAN_QUEUE="\$F2B_DIR/unban-queue"
BAN_QUEUE="\$F2B_DIR/ban-queue"
WL_QUEUE="\$F2B_DIR/whitelist-queue"
META_FILE="\$F2B_DIR/meta.json"
STATS_FILE="\$F2B_DIR/stats.json"
# 锁、日志、临时文件都放在 root 专属目录。F2B_DIR 对 PHP 容器 (www-data) 可写，
# root 若在里面创建/截断文件，可被预先放置的符号链接引向 /etc/shadow 等系统文件
PRIV_DIR="/var/lib/lnmp-f2b"
LOG_FILE="\$PRIV_DIR/bridge.log"

mkdir -p "\$F2B_DIR"
mkdir -p "\$PRIV_DIR" && chmod 700 "\$PRIV_DIR"
EOFBRIDGE

    # 其余脚本主体不含需要插值的变量，用 quoted heredoc 追加 (避免 $ 转义地狱)
    cat >> "$bridge" << 'EOFBRIDGE2'

log_line() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# 防重入: 上一轮还没跑完 (日志大、封禁多时) 就跳过本轮，避免每分钟叠加多个进程抢 CPU
exec 9>"$PRIV_DIR/bridge.lock"
if command -v flock &>/dev/null && ! flock -n 9; then exit 0; fi
# 桥接只是后台统计，让出 CPU 给网站
renice -n 10 $$ >/dev/null 2>&1 || true

# 往共享目录 (PHP 可写) 安全地写一个文件: 先在 root 专属目录写好，再 mv -T 原子替换。
# mv 替换的是目录项本身，目标就算被换成指向系统文件的符号链接，也只是替换掉这个链接，不会写穿
publish() {  # publish <目标路径> <内容来源文件> [权限]
    local dst="$1" src="$2" mode="${3:-644}"
    chmod "$mode" "$src" 2>/dev/null || true
    mv -fT "$src" "$dst" 2>/dev/null || { rm -f "$src"; log_line "publish failed: $dst"; }
}
ptmp() { mktemp "$PRIV_DIR/tmp.XXXXXX"; }

# 合法 IP 校验 (IPv4 或含冒号的 IPv6)，拒绝一切其它字符
is_valid_ip() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
    [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:* ]] && return 0
    return 1
}

# IPv4 是否落在 jail.local 的 ignoreip (含 CIDR) 内。
# fail2ban 的 banip 不检查 ignoreip，面板手动封禁时要自己拦住，
# 否则误封 Cloudflare 节点 / Docker 网桥 / 局域网会让大量正常访问被丢包
# 10# 强制十进制: 「010」「08」这类前导零写法否则会被当八进制甚至报错
ip2int() { local IFS=.; set -- $1; echo $(( (10#$1<<24) + (10#$2<<16) + (10#$3<<8) + 10#$4 )); }
is_ignored_ip() {
    local ip="$1" n net bits mask
    n=$(ip2int "$ip")
    for net in $(grep -m1 -E "^ignoreip\b" "$JAIL_LOCAL" 2>/dev/null | sed -E 's/^ignoreip[[:space:]]*=?//'); do
        [[ "$net" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || continue
        bits=32; [[ "$net" == */* ]] && bits="${net#*/}"
        (( bits <= 32 )) || continue
        mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
        (( (n & mask) == ($(ip2int "${net%/*}") & mask) )) && return 0
    done
    return 1
}

# 原子取走队列内容到 stdout。只 mv 走，不由 root 重建队列文件 —— 面板下次写入时
# 会以 www-data 身份自己创建 (FILE_APPEND)；mv 之后到达的写入落在新文件里，下一轮处理，不会丢。
# 队列是符号链接时直接删掉不读，防止 root 被骗去读写别处的文件。
drain_queue() {
    local q="$1"
    if [[ -L "$q" ]]; then rm -f "$q"; log_line "REJECTED symlink queue: $q"; return 0; fi
    [[ -f "$q" && -s "$q" ]] || return 0
    local tmp; tmp=$(ptmp)
    mv -fT "$q" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    # 只取前 2000 行，防止队列被灌入超大文件拖住 root 进程
    head -n 2000 "$tmp"; rm -f "$tmp"
}

# ---- 2) 消费解封队列 ---- (先处理面板提交的操作，再导出封禁列表，操作当轮就能生效)
while IFS= read -r ip; do
    ip="$(echo "$ip" | tr -d '[:space:]')"; [[ -z "$ip" ]] && continue
    if is_valid_ip "$ip"; then
        fail2ban-client set "$JAIL" unbanip "$ip" >/dev/null 2>&1 \
            && log_line "unbanned $ip" || log_line "unban noop $ip"
        # SSH jail 若存在也一并解封 (误封自己 SSH 时可从面板自救)
        fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1 && log_line "unbanned $ip (sshd)" || true
    else
        log_line "REJECTED invalid unban ip: $ip"
    fi
done < <(drain_queue "$UNBAN_QUEUE")

# ---- 3) 消费手动封禁队列 ----
while IFS= read -r ip; do
    ip="$(echo "$ip" | tr -d '[:space:]')"; [[ -z "$ip" ]] && continue
    if [[ "$ip" == *:* ]]; then
        log_line "SKIP ipv6 ban (IPv6 不封): $ip"
    elif is_valid_ip "$ip" && is_ignored_ip "$ip"; then
        log_line "REJECTED ban of whitelisted ip: $ip"
    elif is_valid_ip "$ip"; then
        fail2ban-client set "$JAIL" banip "$ip" >/dev/null 2>&1 \
            && log_line "banned $ip" || log_line "ban failed $ip"
    else
        log_line "REJECTED invalid ban ip: $ip"
    fi
done < <(drain_queue "$BAN_QUEUE")

# ---- 4) 消费白名单队列: 加入 jail 的 ignoreip (去重) 并解封 ----
WL_CHANGED=0
while IFS= read -r ip; do
    ip="$(echo "$ip" | tr -d '[:space:]')"; [[ -z "$ip" ]] && continue
    if ! is_valid_ip "$ip"; then log_line "REJECTED invalid wl ip: $ip"; continue; fi
    if [[ -f "$JAIL_LOCAL" ]] && grep -qE "^ignoreip\b" "$JAIL_LOCAL"; then
        # 已有 ignoreip 行: 若该 IP 不在其中则追加到行尾
        if ! grep -E "^ignoreip\b" "$JAIL_LOCAL" | grep -qw "$ip"; then
            # 追加到 ignoreip 行尾 ($ 为行尾锚点)；用 awk 避免 sed 转义坑
            awk -v ip="$ip" '/^ignoreip/ && !done {$0=$0" "ip; done=1} {print}' "$JAIL_LOCAL" > "$JAIL_LOCAL.tmp" && mv "$JAIL_LOCAL.tmp" "$JAIL_LOCAL"
            WL_CHANGED=1; log_line "whitelisted $ip"
        fi
    elif [[ -f "$JAIL_LOCAL" ]]; then
        echo "ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fc00::/7 fe80::/10 $ip" >> "$JAIL_LOCAL"
        WL_CHANGED=1; log_line "whitelisted $ip (new line)"
    fi
    # 写进配置文件是为了重启后保留；addignoreip 让网站与 SSH 两个 jail 立即生效，不必重载
    for j in "$JAIL" sshd; do
        fail2ban-client set "$j" addignoreip "$ip" >/dev/null 2>&1 || true
        fail2ban-client set "$j" unbanip "$ip" >/dev/null 2>&1 || true
    done
done < <(drain_queue "$WL_QUEUE")

# ---- 1) 导出当前封禁 IP 列表 (网站 jail -> banned.txt，SSH jail -> banned-sshd.txt) ----
# fail2ban 暂时不可用 (重启/重载中) 时保留上一轮的文件，不能写成空列表 ——
# 否则面板显示 0 个封禁，nginx 层封禁名单也会被清空、整批放行
F2B_OK=0
if command -v fail2ban-client &>/dev/null; then
    for j in "$JAIL" sshd; do
        out="$BANNED_FILE"; [[ "$j" == "sshd" ]] && out="$F2B_DIR/banned-sshd.txt"
        st=$(fail2ban-client status "$j" 2>/dev/null) || continue
        [[ "$j" == "$JAIL" ]] && F2B_OK=1
        t=$(ptmp)
        printf '%s\n' "$st" | grep -oE 'Banned IP list:.*' | sed 's/Banned IP list:[[:space:]]*//' \
            | tr ' ' '\n' | grep -v '^$' > "$t" || true
        # root 自己保留一份 (下面生成 nginx 名单、统计命中都读这份)；共享目录里那份 PHP 可改，不可信
        [[ "$j" == "$JAIL" ]] && cp -f "$t" "$PRIV_DIR/banned.txt"
        publish "$out" "$t" 644
    done
fi

# ---- 1b) 同步 nginx 封禁名单 (geo 格式: 一行一个 "IP 1;")，有变化才重载 nginx ----
# 站点走 Cloudflare 时，连到服务器的是 CF 节点，iptables 按访客 IP 封不住；
# nginx 在真实 IP 还原之后按访客 IP 返回 444，这一层才真正生效。
# 重载最多 5 分钟一次: 扫描高峰名单每分钟都在变，频繁重载会堆积旧 worker
if [[ "$F2B_OK" == "1" && -n "${NGINX_BANLIST:-}" && ! -L "$NGINX_BANLIST" ]]; then
    tmp_bl=$(ptmp)
    { while IFS= read -r bip; do
          # 只写 IPv4，IPv6 不封
          if [[ "$bip" != *:* ]] && is_valid_ip "$bip"; then printf '%s 1;\n' "$bip"; fi
      done < "$PRIV_DIR/banned.txt"; } 2>/dev/null | sort -u > "$tmp_bl" || true
    stamp="$PRIV_DIR/banlist.reloaded"
    if ! cmp -s "$tmp_bl" "$NGINX_BANLIST" 2>/dev/null \
       && [[ ! -f "$stamp" || -n "$(find "$stamp" -mmin +4 2>/dev/null)" ]]; then
        bak=$(ptmp); cp -f "$NGINX_BANLIST" "$bak" 2>/dev/null || : > "$bak"
        # 原地覆盖 (保持 inode)，bind mount 进容器的单文件才能看到新内容
        if cat "$tmp_bl" > "$NGINX_BANLIST" 2>/dev/null; then
            if (cd "$SCRIPT_DIR" && docker compose exec -T nginx nginx -t) >/dev/null 2>&1; then
                (cd "$SCRIPT_DIR" && docker compose exec -T nginx nginx -s reload) >/dev/null 2>&1 \
                    && log_line "nginx banlist reloaded ($(wc -l < "$NGINX_BANLIST") IPs)" || true
                touch "$stamp"
            else
                # 校验失败就还原，避免下次 nginx 重启时因坏名单起不来
                cat "$bak" > "$NGINX_BANLIST" 2>/dev/null || true
                log_line "nginx -t failed with new banlist, reverted"
            fi
        fi
        rm -f "$bak"
    fi
    rm -f "$tmp_bl"
fi

# ---- 5) 导出 meta.json: 每个被封 IP 的命中次数 + 当前白名单 ----
meta_t=$(ptmp)
{
    echo "{"
    echo "  \"updated\": \"$(date '+%F %T')\","
    # 白名单 (从 jail.local 的 ignoreip 行解析)
    wl="[]"
    if [[ -f "$JAIL_LOCAL" ]]; then
        wl=$(grep -E "^ignoreip\b" "$JAIL_LOCAL" 2>/dev/null | head -1 \
             | sed -E 's/^ignoreip[[:space:]]*=?[[:space:]]*//' \
             | tr ' ' '\n' | grep -v '^$' \
             | awk 'BEGIN{printf"["}{printf"%s\"%s\"",(NR>1?",":""),$0}END{printf"]"}')
        [[ -z "$wl" ]] && wl="[]"
    fi
    echo "  \"whitelist\": $wl,"
    # 每个被封 IP 在 access.log 中的命中次数。只扫一遍日志统计全部 IP，
    # 不能每个 IP 各 grep 一次 —— 封禁数上百时就是每分钟上百次全文件扫描，CPU 吃满
    echo "  \"hits\": {"
    if [[ -s "$PRIV_DIR/banned.txt" ]]; then
        awk -v bf="$PRIV_DIR/banned.txt" '
            BEGIN { while ((getline ip < bf) > 0) if (ip ~ /^[0-9a-fA-F.:]+$/) { want[ip]=1; order[++n]=ip } }
            ($1 in want) { cnt[$1]++ }
            END { for (i=1; i<=n; i++) printf "%s    \"%s\": %d", (i>1 ? ",\n" : ""), order[i], cnt[order[i]]+0 }
        ' "$ACCESS_LOG" 2>/dev/null || true
    fi
    echo ""
    echo "  }"
    echo "}"
} > "$meta_t" 2>/dev/null || true
publish "$META_FILE" "$meta_t" 644

# ---- 6) 导出 stats.json: 近 24h 按小时的 444/429/403 计数 + 状态码分布 + Top IP ----
# 从 access.log 解析 (log_format main: ip - user [time] "req" status ...)
if [[ -f "$ACCESS_LOG" ]]; then
    stats_t=$(ptmp)
    # 用 2-arg match + substr 抓状态码 (POSIX，兼容 mawk/gawk/busybox)；
    # 匹配 "...request..." 后紧跟的空格+三位状态码。$1 恒为源 IP。
    awk '
    {
        ip = $1
        if (match($0, /" [0-9][0-9][0-9] /)) {
            st = substr($0, RSTART+2, 3)
            total[st]++
            if (st == "444" || st == "429" || st == "403") {
                ipcount[ip]++
                blocked++
            }
        }
    }
    END {
        printf "{\n"
        printf "  \"blocked_total\": %d,\n", blocked+0
        printf "  \"status\": {"
        sep=""
        for (s in total) { printf "%s\"%s\":%d", sep, s, total[s]; sep="," }
        printf "},\n"
        printf "  \"top_ips\": ["
        for (i=0;i<10;i++) {
            maxk=""; maxv=0
            for (k in ipcount) { if (ipcount[k]>maxv) { maxv=ipcount[k]; maxk=k } }
            if (maxk=="") break
            printf "%s{\"ip\":\"%s\",\"count\":%d}", (i>0?",":""), maxk, maxv
            delete ipcount[maxk]
        }
        printf "]\n"
        printf "}\n"
    }' "$ACCESS_LOG" > "$stats_t" 2>/dev/null || true
    publish "$STATS_FILE" "$stats_t" 644
fi

# ---- 7) IP 归属国家: 用本地 GeoIP 库 (DB-IP Country Lite) 离线查询，结果缓存到 geo-cache.tsv ----
# 全程本地查询，不把 IP 发给任何外部服务。库文件由 geoip_update.sh 每月更新。
GEO_DB="$SCRIPT_DIR/volumes/geoip/dbip-country-lite.mmdb"
# 主缓存放在 root 专属目录里维护，每轮结束后发布一份副本到共享目录给面板读
GEO_CACHE="$PRIV_DIR/geo-cache.tsv"
if [[ -s "$GEO_DB" ]] && command -v mmdblookup &>/dev/null; then
    touch "$GEO_CACHE"
    # 库文件比上次清缓存的时间新 (刚更新过) 就清空缓存，避免沿用旧结果
    if [[ "$GEO_DB" -nt "$PRIV_DIR/geo-cache.stamp" ]]; then : > "$GEO_CACHE"; touch "$PRIV_DIR/geo-cache.stamp"; fi
    want=$( { cat "$F2B_DIR"/banned*.txt 2>/dev/null; grep -oE '"ip":"[^"]+"' "$STATS_FILE" 2>/dev/null | cut -d'"' -f4; } | sort -u ) || true
    # 先在 BEGIN 里读缓存再过滤 stdin。不能用 NR==FNR 双文件写法:
    # 缓存为空时 NR==FNR 会落到 stdin 上，把所有 IP 当缓存吞掉，导致永远不查询
    new_list=$(printf '%s\n' "$want" | awk -F'\t' -v cf="$GEO_CACHE" \
        'BEGIN{while((getline l < cf)>0){split(l,a,"\t");c[a[1]]=1}} NF && !($1 in c)' | head -100)
    # 每个 IP 只调一次 mmdblookup 取整个 country 节点，再从输出里解析 iso_code 与中/英文名。
    # 输出形如:  "iso_code":  换行  "CN" <utf8_string>，值在键的下一行
    printf '%s\n' "$new_list" | while IFS= read -r ip; do
        [[ -n "$ip" ]] && is_valid_ip "$ip" || continue
        geo=$(mmdblookup --file "$GEO_DB" --ip "$ip" country 2>/dev/null | awk '
            /"[^"]+":[[:space:]]*$/ { match($0, /"[^"]+"/); key = substr($0, RSTART+1, RLENGTH-2); next }
            /<utf8_string>/ {
                match($0, /"[^"]*"/); v = substr($0, RSTART+1, RLENGTH-2)
                if (key == "iso_code") cc = v; else if (key == "zh-CN") zh = v; else if (key == "en") en = v
            }
            END { printf "%s\t%s", cc, (zh != "" ? zh : en) }')
        cc=${geo%%$'\t'*}
        cn=$(printf '%s' "${geo#*$'\t'}" | tr -d '\t\r\n<>&' | cut -c1-60)
        if [[ -z "$cc" ]]; then cc="--"; cn="内网/未收录"; fi
        printf '%s\t%s\t%s\n' "$ip" "$cc" "${cn:-未知}" >> "$GEO_CACHE"
    done
    # 缓存最多保留 5000 条
    if (( $(wc -l < "$GEO_CACHE") > 5000 )); then
        t=$(ptmp); tail -n 5000 "$GEO_CACHE" > "$t" && mv -fT "$t" "$GEO_CACHE"
    fi
    t=$(ptmp); cp -f "$GEO_CACHE" "$t" && publish "$F2B_DIR/geo-cache.tsv" "$t" 644
fi

# 日志超过 2MB 截断
if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 2097152 ]]; then
    t=$(ptmp); tail -n 500 "$LOG_FILE" > "$t" && mv -fT "$t" "$LOG_FILE"
fi
# 清理旧版本留在共享目录里的锁/日志/临时文件 (现已改放 root 专属目录)
rm -f "$F2B_DIR/.bridge.lock" "$F2B_DIR/bridge.log" "$F2B_DIR"/*.tmp "$F2B_DIR"/geo-cache.tsv.stamp 2>/dev/null || true
EOFBRIDGE2
    chmod +x "$bridge"

    # 加入 crontab (每分钟)，幂等
    local cron_job="* * * * * $bridge >/dev/null 2>&1"
    local temp_cron; temp_cron=$(mktemp)
    crontab -l > "$temp_cron" 2>/dev/null || true
    if ! grep -q "$bridge" "$temp_cron" 2>/dev/null; then
        echo "$cron_job" >> "$temp_cron"
        crontab "$temp_cron" 2>/dev/null && log "f2b 桥接任务已加入 crontab (每分钟)" \
            || warn "无法添加 f2b 桥接 crontab，请手动添加: $cron_job"
    else
        log "f2b 桥接任务已存在于 crontab"
    fi
    rm -f "$temp_cron"

    # 立即跑一次，生成初始 banned.txt
    bash "$bridge" 2>/dev/null || true
}

# 生成网页解封面板 (PHP) + Basic Auth + nginx include 片段
setup_f2b_panel() {
    step "${ICON_LOCK} 创建独立 fail2ban 面板项目"

    local panel_root="$PROJECT_DIR/fail2ban-panel"
    mkdir -p "$panel_root/public/api" "$panel_root/public/assets" "$panel_root/lib" "$panel_root/config"

    # 生成账号: 随机密码 -> bcrypt hash 写 config/panel.php；明文随 .credentials 打印
    F2B_PANEL_USER="admin"
    F2B_PANEL_PASS=$(generate_strong_password 20)
    local panel_hash session_secret csrf_secret
    # 用 PHP 生成 bcrypt (面板跑在 PHP 容器里，宿主机不一定有 php；用 docker 容器算)
    # || true: PHP 容器还没起来时 exec 失败，pipefail + set -e 会直接退出，走不到下面的兜底
    panel_hash=$(cd "$PROJECT_DIR" && docker compose exec -T php php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$F2B_PANEL_PASS" 2>/dev/null | tr -d '\r\n') || true
    # 兜底: 容器未就绪时用宿主机 php 或占位 (安装脚本会在容器起来后重算)
    if [[ -z "$panel_hash" ]] && command -v php &>/dev/null; then
        panel_hash=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$F2B_PANEL_PASS" 2>/dev/null | tr -d '\r\n')
    fi
    session_secret=$(generate_strong_password 32)
    csrf_secret=$(generate_strong_password 32)

    _f2b_write_panel_files "$panel_root" "$panel_hash" "$session_secret" "$csrf_secret"
    _f2b_write_panel_installer "$panel_root"

    # VERSION / README
    echo "1.0.0" > "$panel_root/VERSION"

    _f2b_write_panel_inc

    # 凭据写入 .credentials (幂等)
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        sed -i '/^解封面板/d' "$CREDENTIALS_FILE" 2>/dev/null || true
    fi
    {
        echo "解封面板地址: https://$DOMAIN/f2b/"
        echo "解封面板用户: ${F2B_PANEL_USER}"
        echo "解封面板密码: ${F2B_PANEL_PASS}"
    } >> "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true

    # 若容器此刻未就绪、hash 为空，记录待办: 安装脚本/收尾会重算
    if [[ -z "$panel_hash" ]]; then
        F2B_PANEL_HASH_PENDING=1
        warn "PHP 容器未就绪，面板密码哈希稍后在容器启动后生成 (见收尾步骤)"
    fi

    log "fail2ban 面板项目创建完成: $panel_root (访问 https://$DOMAIN/f2b/)"
}

# 生成 nginx 片段 location /f2b/ 并注入主域名 443 server 块 (幂等)。
# --setup-waf 与 --update-f2b-panel 都会调用，保证 /f2b/ 入口一定存在。
_f2b_write_panel_inc() {
    local panel_inc panel_inc_in_container
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        panel_inc="$PROJECT_DIR/volumes/nginx/config/nginx/f2b-panel.inc"
        panel_inc_in_container="/config/nginx/f2b-panel.inc"
    else
        panel_inc="$PROJECT_DIR/volumes/nginx/ssl/f2b-panel.inc"
        panel_inc_in_container="/etc/nginx/ssl/f2b-panel.inc"
    fi
    mkdir -p "$(dirname "$panel_inc")"

    cat > "$panel_inc" << 'EOFPANELINC'
# fail2ban 面板 (独立项目，自带登录认证)。全网可访问；如需更严，取消下面两行注释改成你的 IP:
#   allow 1.2.3.4;
#   deny all;
# 旧链接兼容: /f2b-admin.php -> /f2b/
location = /f2b-admin.php { return 301 /f2b/; }
location = /f2b { return 301 /f2b/; }

# 面板 public/ 挂在容器 /var/www/html/_f2bapp/public
location /f2b/ {
    alias /var/www/html/_f2bapp/public/;
    index index.php;
    try_files $uri $uri/ /f2b/index.php?$query_string;

    location ~ ^/f2b/(?<f2bpath>.+\.php)$ {
        alias /var/www/html/_f2bapp/public/$f2bpath;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME /var/www/html/_f2bapp/public/$f2bpath;
        include fastcgi_params;
    }
}
EOFPANELINC

    _inject_panel_include "$panel_inc_in_container"
}

# 生成面板 PHP 源码 (public/ + lib/ + config/)
_f2b_write_panel_files() {
    local root="$1" pass_hash="$2" sess="$3" csrf="$4"

    # ---- config/panel.php ----
    # 传入 "__keep__" 表示只升级面板代码、保留现有账号密码 (见 cmd_update_f2b_panel)
    if [[ "$pass_hash" != "__keep__" ]]; then
    cat > "$root/config/panel.php" << EOFCFG
<?php
// fail2ban 面板配置 (由 deploy.sh 生成)。请勿公开此文件。
return [
    'user'          => 'admin',
    'pass_hash'     => '${pass_hash}',
    'session_name'  => 'f2bpanel',
    'session_secret'=> '${sess}',
    'csrf_secret'   => '${csrf}',
    'f2b_dir'       => '/var/f2b',          // 与宿主机 volumes/fail2ban 映射
    'max_fails'     => 5,                     // 登录失败次数阈值
    'lock_seconds'  => 900,                   // 锁定时长 (15 分钟)
];
EOFCFG
    # 含 bcrypt hash 与 secret，限权 640 (属主 root 写、php 容器 www-data 同组读)，
    # 不对宿主机其他本地用户开放。文件在 public/ 之外，本就不经 web 暴露。
    chown root:82 "$root/config/panel.php" 2>/dev/null || true
    chmod 640 "$root/config/panel.php" 2>/dev/null || true
    fi

    # ---- lib/auth.php ----
    cat > "$root/lib/auth.php" << 'EOFAUTH'
<?php
// 会话 / 登录 / CSRF / 失败锁定
function f2b_cfg() { static $c; if(!$c){ $c = require dirname(__DIR__).'/config/panel.php'; } return $c; }

function f2b_session_start() {
    $c = f2b_cfg();
    session_name($c['session_name']);
    session_set_cookie_params([
        'lifetime' => 0, 'path' => '/f2b/', 'httponly' => true,
        'samesite' => 'Strict', 'secure' => (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS']!=='off'),
    ]);
    session_start();
}

function f2b_is_logged_in() { return !empty($_SESSION['f2b_auth']); }

function f2b_require_login() {
    // 绝对路径: 从 /f2b/api/ 下相对跳转会落到不存在的 /f2b/api/login.php
    if (!f2b_is_logged_in()) { header('Location: /f2b/login.php'); exit; }
}

// 失败锁定: 按客户端 IP 分桶存到 f2b_dir/.login_fails (JSON: {ip:{fails,until}})。
// 按 IP 计数而非全局——否则攻击者可持续失败把管理员永久锁在门外 (DoS)。
function f2b_lock_file() { return f2b_cfg()['f2b_dir'] . '/.login_fails'; }
function f2b_client_ip() {
    // 只用 REMOTE_ADDR。nginx 的 real_ip 已只对 Cloudflare 网段把它还原成真实访客 IP；
    // 不能直接读 CF-Connecting-IP / X-Real-IP 请求头——客户端可随意伪造，每次换一个就能绕过锁定
    $ip = $_SERVER['REMOTE_ADDR'] ?? '';
    return filter_var($ip, FILTER_VALIDATE_IP) ? $ip : 'unknown';
}
function f2b_read_locks() {
    $f = f2b_lock_file();
    if (is_readable($f)) { $d = json_decode(@file_get_contents($f), true); if (is_array($d)) return $d; }
    return [];
}
function f2b_write_locks($d){ @file_put_contents(f2b_lock_file(), json_encode($d), LOCK_EX); }
function f2b_lock_entry($ip){ $all=f2b_read_locks(); return $all[$ip] ?? ['fails'=>0,'until'=>0]; }
function f2b_is_locked(){ $e=f2b_lock_entry(f2b_client_ip()); return ($e['until'] ?? 0) > time(); }
function f2b_lock_remaining(){ $e=f2b_lock_entry(f2b_client_ip()); return max(0, ($e['until'] ?? 0) - time()); }

function f2b_try_login($user, $pass) {
    $c = f2b_cfg();
    $ip = f2b_client_ip();
    if (f2b_is_locked()) return false;
    // 非字符串输入 (如 pass[]=x) 当作空串，避免 PHP 8 TypeError 500 且绕过失败计数
    $user = is_string($user) ? $user : '';
    $pass = is_string($pass) ? $pass : '';
    $ok = hash_equals($c['user'], $user) && !empty($c['pass_hash']) && password_verify($pass, $c['pass_hash']);
    $all = f2b_read_locks();
    // 顺带清理过期条目，避免文件无限增长: 锁定已过期，且最后一次失败也在一个锁定周期之前
    $now = time();
    foreach ($all as $k => $v) {
        if (($v['until'] ?? 0) < $now && ($v['last'] ?? 0) < $now - $c['lock_seconds']) unset($all[$k]);
    }
    if ($ok) {
        session_regenerate_id(true);
        $_SESSION['f2b_auth'] = true;
        $_SESSION['f2b_user'] = $user;
        unset($all[$ip]);
        f2b_write_locks($all);
        return true;
    }
    $e = $all[$ip] ?? ['fails'=>0, 'until'=>0];
    $e['fails'] = ($e['fails'] ?? 0) + 1;
    $e['last']  = $now;
    if ($e['fails'] >= $c['max_fails']) { $e['until'] = time() + $c['lock_seconds']; $e['fails'] = 0; }
    $all[$ip] = $e;
    f2b_write_locks($all);
    return false;
}

function f2b_logout() { $_SESSION = []; session_destroy(); }

// CSRF
function f2b_csrf_token() {
    if (empty($_SESSION['f2b_csrf'])) { $_SESSION['f2b_csrf'] = bin2hex(random_bytes(16)); }
    return $_SESSION['f2b_csrf'];
}
function f2b_csrf_check($t) { return is_string($t) && !empty($_SESSION['f2b_csrf']) && hash_equals($_SESSION['f2b_csrf'], $t); }
EOFAUTH

    # ---- lib/queue.php ----
    cat > "$root/lib/queue.php" << 'EOFQUEUE'
<?php
// 往 /var/f2b 下的队列安全追加 (仅合法 IP)。PHP 永不执行 fail2ban-client。
require_once __DIR__ . '/auth.php';

function f2b_valid_ip($ip){ return filter_var($ip, FILTER_VALIDATE_IP) !== false; }

function f2b_enqueue($action, $ip) {
    $map = ['unban'=>'unban-queue', 'ban'=>'ban-queue', 'whitelist'=>'whitelist-queue'];
    if (!isset($map[$action])) return [false, '未知操作'];
    $ip = trim($ip);
    if (!f2b_valid_ip($ip)) return [false, '无效的 IP 地址'];
    if ($action === 'ban' && strpos($ip, ':') !== false) return [false, 'IPv6 地址不封禁'];
    $file = f2b_cfg()['f2b_dir'] . '/' . $map[$action];
    if (@file_put_contents($file, $ip . "\n", FILE_APPEND | LOCK_EX) === false) {
        return [false, '写入队列失败 (检查目录权限)'];
    }
    @chmod($file, 0660);  // 仅属主(www-data)与同组可写，不对全机开放
    return [true, '已提交，约 1 分钟内生效'];
}

// 读 JSON 状态文件 (banned/meta/stats)
function f2b_read_json($name) {
    $f = f2b_cfg()['f2b_dir'] . '/' . $name;
    if (!is_readable($f)) return null;
    return json_decode(@file_get_contents($f), true);
}
function f2b_banned_list($file = 'banned.txt') {
    $f = f2b_cfg()['f2b_dir'] . '/' . $file;
    if (!is_readable($f)) return [];
    // 只保留合法 IP: 该目录 PHP 进程可写，不校验的话被篡改的内容会原样输出到页面
    return array_values(array_filter(array_map('trim', file($f)), 'f2b_valid_ip'));
}

// IP 归属国家缓存 (由 f2b_bridge.sh 每分钟批量查询写入: ip \t 国家代码 \t 国家名)
function f2b_geo_map() {
    static $m = null;
    if ($m !== null) return $m;
    $m = [];
    $f = f2b_cfg()['f2b_dir'] . '/geo-cache.tsv';
    if (!is_readable($f)) return $m;
    foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $p = explode("\t", $line);
        if (count($p) >= 3) $m[$p[0]] = ['cc' => $p[1], 'name' => $p[2]];
    }
    return $m;
}
// 国家代码 -> 国旗 emoji (两个区域指示符)
function f2b_flag($cc) {
    if (!preg_match('/^[A-Z]{2}$/', (string)$cc)) return '🏳️';
    return mb_chr(0x1F1E6 + ord($cc[0]) - 65) . mb_chr(0x1F1E6 + ord($cc[1]) - 65);
}
function f2b_geo_label($ip) {
    $g = f2b_geo_map()[$ip] ?? null;
    if (!$g) return ['flag' => '🌐', 'name' => '未知'];
    return ['flag' => f2b_flag($g['cc']), 'name' => $g['name']];
}
EOFQUEUE

    # ---- lib/guard.php (每个受保护页面 require) ----
    cat > "$root/lib/guard.php" << 'EOFGUARD'
<?php
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/queue.php';
f2b_session_start();
f2b_require_login();
EOFGUARD

    # ---- public/login.php ----
    cat > "$root/public/login.php" << 'EOFLOGIN'
<?php
require_once dirname(__DIR__).'/lib/auth.php';
f2b_session_start();
if (f2b_is_logged_in()) { header('Location: index.php'); exit; }
$err = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!f2b_csrf_check($_POST['csrf'] ?? '')) {
        $err = '会话已过期，请重试';
    } elseif (f2b_is_locked()) {
        $err = '登录失败次数过多，请 '.ceil(f2b_lock_remaining()/60).' 分钟后再试';
    } elseif (f2b_try_login($_POST['user'] ?? '', $_POST['pass'] ?? '')) {
        header('Location: index.php'); exit;
    } else {
        $err = f2b_is_locked() ? '失败过多，账号已临时锁定' : '用户名或密码错误';
    }
}
$token = f2b_csrf_token();
?>
<!DOCTYPE html><html lang="zh-CN" class="dark"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>登录 · fail2ban 面板</title>
<script src="https://cdn.tailwindcss.com"></script>
<link rel="stylesheet" href="assets/app.css">
</head>
<body class="min-h-screen flex items-center justify-center bg-slate-950 text-slate-100">
  <div class="w-full max-w-sm p-8 rounded-2xl bg-slate-900/80 shadow-2xl border border-slate-800">
    <div class="text-center mb-6">
      <div class="text-4xl mb-2">🛡️</div>
      <h1 class="text-xl font-semibold">fail2ban 面板</h1>
      <p class="text-slate-400 text-sm mt-1">请登录以管理封禁</p>
    </div>
    <?php if($err): ?><div class="mb-4 text-sm text-rose-300 bg-rose-950/50 border border-rose-900 rounded-lg px-3 py-2"><?= htmlspecialchars($err) ?></div><?php endif; ?>
    <form method="post" class="space-y-4">
      <input type="hidden" name="csrf" value="<?= htmlspecialchars($token) ?>">
      <div>
        <label class="block text-xs text-slate-400 mb-1">用户名</label>
        <input name="user" autocomplete="username" class="w-full px-3 py-2 rounded-lg bg-slate-800 border border-slate-700 focus:border-indigo-500 outline-none" required>
      </div>
      <div>
        <label class="block text-xs text-slate-400 mb-1">密码</label>
        <input name="pass" type="password" autocomplete="current-password" class="w-full px-3 py-2 rounded-lg bg-slate-800 border border-slate-700 focus:border-indigo-500 outline-none" required>
      </div>
      <button class="w-full py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 font-medium transition">登 录</button>
    </form>
  </div>
</body></html>
EOFLOGIN

    # ---- public/logout.php ----
    cat > "$root/public/logout.php" << 'EOFLOGOUT'
<?php
require_once dirname(__DIR__).'/lib/auth.php';
f2b_session_start();
f2b_logout();
header('Location: login.php');
EOFLOGOUT

    # ---- public/action.php (POST + CSRF -> 入队) ----
    cat > "$root/public/action.php" << 'EOFACTION'
<?php
require_once dirname(__DIR__).'/lib/guard.php';
header('Content-Type: application/json');
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); echo '{}'; exit; }
// CSRF 失败返回 400 而非 403: fail2ban 按 403 计数，旧标签页多点几次会把管理员自己封掉
if (!f2b_csrf_check($_POST['csrf'] ?? '')) { http_response_code(400); echo json_encode(['ok'=>false,'msg'=>'会话已过期，请刷新页面后重试']); exit; }
$action = is_string($_POST['action'] ?? null) ? $_POST['action'] : '';
$ip     = is_string($_POST['ip'] ?? null) ? $_POST['ip'] : '';
list($ok, $msg) = f2b_enqueue($action, $ip);
echo json_encode(['ok'=>$ok, 'msg'=>$msg]);
EOFACTION

    # ---- public/api/stats.php (返回 stats/meta/banned 合并 JSON) ----
    cat > "$root/public/api/stats.php" << 'EOFSTATS'
<?php
require_once dirname(dirname(__DIR__)).'/lib/guard.php';
header('Content-Type: application/json');
echo json_encode([
    'banned' => f2b_banned_list(),
    'meta'   => f2b_read_json('meta.json'),
    'stats'  => f2b_read_json('stats.json'),
]);
EOFSTATS

    # ---- public/index.php (仪表盘) ----
    cat > "$root/public/index.php" << 'EOFINDEX'
<?php
require_once dirname(__DIR__).'/lib/guard.php';
$token = f2b_csrf_token();
$banned     = f2b_banned_list();
$banned_ssh = f2b_banned_list('banned-sshd.txt');
$meta   = f2b_read_json('meta.json') ?: [];
$stats  = f2b_read_json('stats.json') ?: [];
$hits   = $meta['hits'] ?? [];
$whitelist = $meta['whitelist'] ?? [];
$blocked24 = $stats['blocked_total'] ?? 0;
$top_ips   = $stats['top_ips'] ?? [];

// 封禁列表: 网站 + SSH 合并，每页 10 条
$rows = [];
foreach ($banned as $ip)     $rows[] = ['ip' => $ip, 'jail' => '网站', 'hits' => (int)($hits[$ip] ?? 0)];
foreach ($banned_ssh as $ip) $rows[] = ['ip' => $ip, 'jail' => 'SSH',  'hits' => null];
$total_all = count($rows);

// 搜索: 按 IP 子串匹配 (支持输入前缀如 "106.8." 查一整段)，只保留 IP 合法字符
$q = preg_replace('/[^0-9a-fA-F.:]/', '', (string)($_GET['q'] ?? ''));
$q = substr($q, 0, 45);
if ($q !== '') {
    $rows = array_values(array_filter($rows, fn($r) => stripos($r['ip'], $q) !== false));
}
// 搜索词是完整 IP: 判断它当前的状态，便于直接封禁/解封
$q_is_ip       = $q !== '' && filter_var($q, FILTER_VALIDATE_IP) !== false;
$q_banned      = $q_is_ip && (in_array($q, $banned, true) || in_array($q, $banned_ssh, true));
// IPv6 不封 (白名单里的 ::/0)，搜索 IPv6 时直接显示为白名单，不给封禁按钮
$q_whitelisted = $q_is_ip && (in_array($q, $whitelist, true) || strpos($q, ':') !== false);

$per_page = 10;
$total    = count($rows);
$pages    = max(1, (int)ceil($total / $per_page));
$page     = min($pages, max(1, (int)($_GET['page'] ?? 1)));
$page_rows = array_slice($rows, ($page - 1) * $per_page, $per_page);
?>
<!DOCTYPE html><html lang="zh-CN" class="dark"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>fail2ban 面板</title>
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<link rel="stylesheet" href="assets/app.css">
</head>
<body class="min-h-screen bg-slate-950 text-slate-100">
<div class="max-w-6xl mx-auto px-4 py-6">
  <!-- 顶部状态条 -->
  <header class="flex items-center justify-between mb-6">
    <div class="flex items-center gap-3">
      <span class="text-3xl">🛡️</span>
      <div><h1 class="text-lg font-semibold">fail2ban 面板</h1>
      <p class="text-xs text-slate-400">WAF / 限流 / SSH 爆破触发的封禁管理</p></div>
    </div>
    <a href="logout.php" class="text-sm text-slate-400 hover:text-slate-200">退出登录</a>
  </header>

  <!-- 统计卡片 -->
  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-6">
    <div class="rounded-2xl bg-slate-900 border border-slate-800 p-5">
      <div class="text-xs text-slate-400">当前封禁 IP</div>
      <div class="text-3xl font-bold mt-1"><?= $total_all ?></div>
      <div class="text-xs text-slate-500 mt-1">网站 <?= count($banned) ?> · SSH <?= count($banned_ssh) ?></div>
    </div>
    <div class="rounded-2xl bg-slate-900 border border-slate-800 p-5">
      <div class="text-xs text-slate-400">日志内拦截次数 (444/429/403)</div>
      <div class="text-3xl font-bold mt-1"><?= (int)$blocked24 ?></div>
    </div>
    <div class="rounded-2xl bg-slate-900 border border-slate-800 p-5">
      <div class="text-xs text-slate-400">白名单条数</div>
      <div class="text-3xl font-bold mt-1"><?= count($whitelist) ?></div>
    </div>
  </div>

  <!-- 图表 -->
  <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-6">
    <div class="rounded-2xl bg-slate-900 border border-slate-800 p-5">
      <h2 class="text-sm font-medium mb-3">状态码分布</h2>
      <canvas id="statusChart" height="180"></canvas>
    </div>
    <div class="rounded-2xl bg-slate-900 border border-slate-800 p-5">
      <h2 class="text-sm font-medium mb-3">Top 攻击源 IP</h2>
      <canvas id="topChart" height="180"></canvas>
    </div>
  </div>

  <!-- 手动封禁 -->
  <div class="rounded-2xl bg-slate-900 border border-slate-800 p-5 mb-6">
    <h2 class="text-sm font-medium mb-3">手动操作</h2>
    <div class="flex flex-wrap gap-2 items-center">
      <input id="manualIp" placeholder="输入 IP 地址" class="px-3 py-2 rounded-lg bg-slate-800 border border-slate-700 outline-none text-sm">
      <button onclick="doAction('ban', document.getElementById('manualIp').value)" class="px-4 py-2 rounded-lg bg-rose-600 hover:bg-rose-500 text-sm">封禁</button>
      <button onclick="doAction('whitelist', document.getElementById('manualIp').value)" class="px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-sm">加白名单</button>
    </div>
  </div>

  <!-- 封禁列表 -->
  <div class="rounded-2xl bg-slate-900 border border-slate-800 overflow-hidden mb-6">
    <div class="flex flex-wrap items-center justify-between gap-3 px-5 py-4 border-b border-slate-800">
      <h2 class="text-sm font-medium">当前封禁 IP
        <span class="text-slate-500 font-normal">
          <?= $q !== '' ? '(匹配 '.$total.' / 共 '.$total_all.' 个)' : '(共 '.$total_all.' 个)' ?>
        </span>
      </h2>
      <form method="get" class="flex items-center gap-2">
        <input name="q" value="<?= htmlspecialchars($q) ?>" placeholder="搜索 IP 或网段前缀，如 106.8."
               autocomplete="off" spellcheck="false"
               class="w-60 px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-700 focus:border-indigo-500 outline-none text-sm font-mono">
        <button class="px-3 py-1.5 rounded-lg bg-slate-700 hover:bg-slate-600 text-sm">搜索</button>
        <?php if ($q !== ''): ?><a href="?" class="text-xs text-slate-400 hover:text-slate-200">清除</a><?php endif; ?>
      </form>
    </div>
    <?php if ($q_is_ip): ?>
    <!-- 搜索的是完整 IP: 显示其状态并给出对应操作 -->
    <div class="flex flex-wrap items-center gap-3 px-5 py-3 border-b border-slate-800 bg-slate-950/40 text-sm">
      <span class="font-mono"><?= htmlspecialchars($q) ?></span>
      <?php $g = f2b_geo_label($q); ?><span class="text-slate-400"><?= $g['flag'] ?> <?= htmlspecialchars($g['name']) ?></span>
      <?php if ($q_whitelisted): ?>
        <span class="px-2 py-0.5 rounded text-xs bg-emerald-900/60 text-emerald-200">已在白名单</span>
      <?php elseif ($q_banned): ?>
        <span class="px-2 py-0.5 rounded text-xs bg-rose-900/60 text-rose-200">封禁中</span>
        <button onclick="doAction('unban','<?= htmlspecialchars($q, ENT_QUOTES) ?>')" class="px-3 py-1 rounded bg-indigo-600 hover:bg-indigo-500 text-xs">解封</button>
        <button onclick="doAction('whitelist','<?= htmlspecialchars($q, ENT_QUOTES) ?>')" class="px-3 py-1 rounded bg-emerald-700 hover:bg-emerald-600 text-xs">加白</button>
      <?php else: ?>
        <span class="px-2 py-0.5 rounded text-xs bg-slate-800 text-slate-300">未封禁</span>
        <button onclick="doAction('ban','<?= htmlspecialchars($q, ENT_QUOTES) ?>')" class="px-3 py-1 rounded bg-rose-600 hover:bg-rose-500 text-xs">封禁</button>
        <button onclick="doAction('whitelist','<?= htmlspecialchars($q, ENT_QUOTES) ?>')" class="px-3 py-1 rounded bg-emerald-700 hover:bg-emerald-600 text-xs">加白</button>
      <?php endif; ?>
    </div>
    <?php endif; ?>
    <div class="overflow-x-auto">
    <table class="w-full text-sm">
      <thead class="text-xs text-slate-500 uppercase">
        <tr>
          <th class="text-left px-5 py-2">IP</th>
          <th class="text-left px-5 py-2">国家/地区</th>
          <th class="text-left px-5 py-2">来源</th>
          <th class="text-left px-5 py-2">命中次数</th>
          <th class="text-right px-5 py-2">操作</th>
        </tr>
      </thead>
      <tbody id="banTable">
      <?php if (!$total): ?>
        <tr><td colspan="5" class="text-center text-slate-500 py-8"><?= $q !== '' ? '没有匹配「'.htmlspecialchars($q).'」的封禁 IP' : '当前没有被封禁的 IP 🎉' ?></td></tr>
      <?php else: foreach ($page_rows as $r): $ip = $r['ip']; $g = f2b_geo_label($ip); $ipq = htmlspecialchars($ip, ENT_QUOTES); ?>
        <tr class="border-t border-slate-800">
          <td class="px-5 py-3">
            <button onclick="copyText('<?= $ipq ?>')" title="点击复制" class="font-mono hover:text-indigo-300"><?= htmlspecialchars($ip) ?> <span class="text-slate-500 text-xs">⧉</span></button>
          </td>
          <td class="px-5 py-3 whitespace-nowrap"><?= $g['flag'] ?> <?= htmlspecialchars($g['name']) ?></td>
          <td class="px-5 py-3">
            <span class="px-2 py-0.5 rounded text-xs <?= $r['jail'] === 'SSH' ? 'bg-amber-900/60 text-amber-200' : 'bg-slate-800 text-slate-300' ?>"><?= $r['jail'] ?></span>
          </td>
          <td class="px-5 py-3"><?= $r['hits'] === null ? '<span class="text-slate-500">—</span>' : (int)$r['hits'] ?></td>
          <td class="px-5 py-3 text-right whitespace-nowrap">
            <button onclick="doAction('unban','<?= $ipq ?>')" class="px-3 py-1 rounded bg-indigo-600 hover:bg-indigo-500 text-xs">解封</button>
            <button onclick="doAction('whitelist','<?= $ipq ?>')" class="px-3 py-1 rounded bg-emerald-700 hover:bg-emerald-600 text-xs">加白</button>
          </td>
        </tr>
      <?php endforeach; endif; ?>
      </tbody>
    </table>
    </div>
    <?php if ($pages > 1): ?>
    <nav class="flex items-center justify-center gap-1 px-5 py-3 border-t border-slate-800 text-sm">
      <?php
        // 翻页链接带上搜索词，搜索结果也能分页
        $link = function($p, $label, $active = false, $disabled = false) use ($q) {
            if ($disabled) return '<span class="px-3 py-1 rounded text-slate-600">'.$label.'</span>';
            $cls = $active ? 'bg-indigo-600 text-white' : 'bg-slate-800 hover:bg-slate-700';
            $params = ['page' => $p];
            if ($q !== '') $params = ['q' => $q] + $params;
            $href = '?'.htmlspecialchars(http_build_query($params), ENT_QUOTES);
            return '<a href="'.$href.'" class="px-3 py-1 rounded '.$cls.'">'.$label.'</a>';
        };
        echo $link($page - 1, '‹ 上一页', false, $page <= 1);
        $from = max(1, $page - 2); $to = min($pages, $page + 2);
        if ($from > 1) { echo $link(1, '1'); if ($from > 2) echo '<span class="px-1 text-slate-600">…</span>'; }
        for ($p = $from; $p <= $to; $p++) echo $link($p, (string)$p, $p === $page);
        if ($to < $pages) { if ($to < $pages - 1) echo '<span class="px-1 text-slate-600">…</span>'; echo $link($pages, (string)$pages); }
        echo $link($page + 1, '下一页 ›', false, $page >= $pages);
      ?>
    </nav>
    <?php endif; ?>
  </div>

  <!-- 白名单 -->
  <div class="rounded-2xl bg-slate-900 border border-slate-800 p-5">
    <h2 class="text-sm font-medium mb-3">白名单 (ignoreip)</h2>
    <div class="flex flex-wrap gap-2">
      <?php if (empty($whitelist)): ?>
        <span class="text-slate-500 text-sm">暂无</span>
      <?php else: foreach ($whitelist as $w): ?>
        <span class="px-3 py-1 rounded-full bg-slate-800 text-xs font-mono"><?= htmlspecialchars($w) ?></span>
      <?php endforeach; endif; ?>
    </div>
  </div>
</div>

<div id="toast" class="fixed bottom-6 right-6 px-4 py-3 rounded-lg bg-slate-800 border border-slate-700 text-sm shadow-xl opacity-0 transition pointer-events-none"></div>

<script>
window.F2B_CSRF = <?= json_encode($token) ?>;
window.F2B_STATS = <?= json_encode($stats) ?>;
</script>
<script src="assets/app.js"></script>
</body></html>
EOFINDEX

    # ---- public/assets/app.css ----
    cat > "$root/public/assets/app.css" << 'EOFCSS'
/* 额外微调 (Tailwind 走 CDN，这里只放少量补充) */
body { -webkit-font-smoothing: antialiased; }
canvas { max-height: 220px; }
EOFCSS

    # ---- public/assets/app.js ----
    cat > "$root/public/assets/app.js" << 'EOFJS'
// toast 提示
function toast(msg, ok) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.style.borderColor = ok ? '#10b981' : '#f43f5e';
  t.style.opacity = '1';
  setTimeout(() => { t.style.opacity = '0'; }, 3500);
}

// 一键复制 IP (优先 Clipboard API，非安全上下文回退到 execCommand)
async function copyText(text, okMsg) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (e) {
    const ta = document.createElement('textarea');
    ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); } catch (_) { toast('复制失败，请手动选择', false); ta.remove(); return; }
    ta.remove();
  }
  toast(okMsg || ('已复制 ' + text), true);
}

// 统一动作: 封/解/白名单 -> POST action.php
async function doAction(action, ip) {
  if (!ip) { toast('请输入 IP', false); return; }
  if (action === 'ban' && !confirm('确认封禁 ' + ip + ' ?')) return;
  const body = new URLSearchParams({ action, ip, csrf: window.F2B_CSRF });
  try {
    const r = await fetch('action.php', { method: 'POST', body });
    const j = await r.json();
    toast(j.msg || (j.ok ? '已提交' : '失败'), j.ok);
    if (j.ok) setTimeout(() => location.reload(), 2000);
  } catch (e) { toast('请求失败', false); }
}

// 渲染图表
(function renderCharts() {
  const s = window.F2B_STATS || {};
  const chartDefaults = { plugins: { legend: { labels: { color: '#cbd5e1' } } },
    scales: { x: { ticks: { color: '#94a3b8' } }, y: { ticks: { color: '#94a3b8' } } } };

  // 状态码分布 (环形)
  const st = s.status || {};
  const stLabels = Object.keys(st);
  if (stLabels.length) {
    new Chart(document.getElementById('statusChart'), {
      type: 'doughnut',
      data: { labels: stLabels, datasets: [{ data: stLabels.map(k => st[k]),
        backgroundColor: ['#6366f1','#f43f5e','#f59e0b','#10b981','#06b6d4','#a855f7'] }] },
      options: { plugins: { legend: { labels: { color: '#cbd5e1' } } } }
    });
  }

  // Top IP (横向柱)
  const top = s.top_ips || [];
  if (top.length) {
    new Chart(document.getElementById('topChart'), {
      type: 'bar',
      data: { labels: top.map(x => x.ip), datasets: [{ label: '拦截次数',
        data: top.map(x => x.count), backgroundColor: '#6366f1' }] },
      options: { indexAxis: 'y', ...chartDefaults,
        scales: {
          x: { ticks: { color: '#94a3b8' } },
          // autoSkip: false —— 10 个 IP 标签全部显示，不再隔一个省略
          y: { ticks: { color: '#cbd5e1', autoSkip: false, font: { family: 'ui-monospace, monospace', size: 12 } } }
        } }
    });
  }
})();

// 每 30 秒刷新一次数据 (轻量: 重新拉 stats 并重载)
setInterval(() => { fetch('api/stats.php').then(r => r.json()).then(() => {}).catch(()=>{}); }, 30000);
EOFJS
}

# 生成面板独立安装脚本 (可脱离 deploy.sh 单独运行)
_f2b_write_panel_installer() {
    local root="$1"
    cat > "$root/install-panel.sh" << 'EOFINSTALLER'
#!/usr/bin/env bash
# fail2ban 面板 — 独立一键安装脚本
# 可在已部署 LNMP Docker 的目录上层运行，装齐 fail2ban + WAF + 面板。
# 它本质是 deploy.sh --setup-waf 的瘦封装: 优先调用同目录/上级的 deploy.sh。
set -eo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 面板项目位于 <PROJECT_DIR>/fail2ban-panel，deploy.sh 在 <PROJECT_DIR>/deploy.sh
PROJECT_DIR="$(dirname "$HERE")"
DEPLOY="$PROJECT_DIR/deploy.sh"

if [[ $EUID -ne 0 ]]; then echo "请用 root 或 sudo 运行"; exit 1; fi

if [[ -x "$DEPLOY" ]]; then
    echo "调用 $DEPLOY --setup-waf 完成安装..."
    exec "$DEPLOY" --setup-waf
else
    echo "未找到 $DEPLOY。"
    echo "本面板依赖 deploy.sh 部署的 LNMP Docker 栈 (提供 PHP 容器与 /var/f2b 挂载)。"
    echo "请把本 fail2ban-panel/ 目录放到 deploy.sh 所在项目目录下，再运行本脚本。"
    exit 1
fi
EOFINSTALLER
    chmod +x "$root/install-panel.sh"

    # README
    cat > "$root/README.md" << 'EOFREADMEPANEL'
# fail2ban 面板

独立的 fail2ban Web 管理面板，配合 LNMP Docker 栈 (deploy.sh) 使用。

## 功能
- 仪表盘: 封禁数 / 拦截次数 / 白名单数 + 状态码分布、Top 攻击源 IP 图表
- 封禁列表: 查看被封 IP 与命中次数，一键解封 / 加白名单
- 手动封禁任意 IP
- 登录认证 (bcrypt + 失败锁定 + CSRF)，默认全网可访问

## 安全模型 (队列隔离)
面板 PHP **从不**直接调用 `fail2ban-client` 或 iptables。
所有封/解/白名单操作都写入 `volumes/fail2ban/*-queue` 队列文件，
由宿主机 root 的 `f2b_bridge.sh` (每分钟 cron) **校验 IP 合法后**执行。
→ 即使面板被攻破，攻击者最多误操作 IP，拿不到宿主机权限。
→ 代价: 网页操作后最长约 1 分钟生效。

## 安装
```bash
sudo ./install-panel.sh        # 等价于 deploy.sh --setup-waf
```

## 默认账号
用户名 `admin`，密码见部署目录的 `.credentials` 文件 (`解封面板密码`)。
EOFREADMEPANEL
}

# 容器就绪后计算/回填面板密码 bcrypt hash (安装时 PHP 容器可能还没起)
# 幂等: 仅当 config/panel.php 的 pass_hash 为空时才重算。
_f2b_finalize_hash() {
    local cfg="$PROJECT_DIR/fail2ban-panel/config/panel.php"
    [[ -f "$cfg" ]] || return 0
    # 已有非空 hash 则跳过
    if grep -qE "'pass_hash'\s*=>\s*'[^']+'" "$cfg" 2>/dev/null; then
        return 0
    fi
    [[ -z "${F2B_PANEL_PASS:-}" ]] && { warn "面板密码未知，无法回填哈希 (请用 --setup-waf 重建面板)"; return 0; }
    local h
    h=$(cd "$PROJECT_DIR" && docker compose exec -T php php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$F2B_PANEL_PASS" 2>/dev/null | tr -d '\r\n') || true
    if [[ -n "$h" ]]; then
        # 转义 hash 里的 / 和 & 供 sed 安全替换
        local h_esc; h_esc=$(printf '%s' "$h" | sed -e 's/[\/&]/\\&/g')
        sed -i "s/'pass_hash'[[:space:]]*=>[[:space:]]*''/'pass_hash'     => '${h_esc}'/" "$cfg"
        log "面板密码哈希已生成"
    else
        warn "仍无法生成面板哈希，请确认 PHP 容器已运行"
    fi
}

# 重置/查询 fail2ban 网页面板密码。
# 面板密码在 config/panel.php 中仅以 bcrypt 保存 (不可逆)，明文只在安装时写入
# .credentials。若 .credentials 丢失该行，明文已无法找回，只能重设新密码。
cmd_reset_f2b_password() {
    step "${ICON_LOCK} 重置 fail2ban 面板密码"

    local cfg="$PROJECT_DIR/fail2ban-panel/config/panel.php"
    [[ -f "$cfg" ]] || error "未找到面板配置 $cfg，请先运行 $0 --setup-waf"
    [[ -f "$PROJECT_DIR/.env" ]] && source "$PROJECT_DIR/.env"
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"

    # 确认 PHP 容器可用 (算 bcrypt 要用它)
    if ! docker compose exec -T php php -v >/dev/null 2>&1; then
        error "PHP 容器未运行，无法生成密码哈希。请先 $0 --restart"
    fi

    echo ""
    echo -e "  ${DIM}面板用户名固定为 ${BOLD}admin${NC}${DIM}。此操作只改面板登录密码，不影响封禁数据。${NC}"
    echo -e "  ${DIM}留空直接回车则自动生成一个 20 位强密码。${NC}"
    echo ""
    printf "${GREEN}  请输入新密码 (回车=自动生成): ${NC}"
    local new_pass=""; IFS= read -rs new_pass; echo ""
    if [[ -z "$new_pass" ]]; then
        new_pass=$(generate_strong_password 20)
        info "已自动生成密码"
    fi

    # 生成 bcrypt 哈希
    local h
    h=$(docker compose exec -T php php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$new_pass" 2>/dev/null | tr -d '\r\n') || true
    [[ -n "$h" ]] || error "密码哈希生成失败，请确认 PHP 容器正常"

    # 写回 panel.php (兼容原值为空或已有旧哈希两种情况；用 | 作 sed 分隔符避开哈希里的 /)
    local h_esc; h_esc=$(printf '%s' "$h" | sed -e 's/[|&]/\\&/g')
    sed -i "s|'pass_hash'[[:space:]]*=>[[:space:]]*'[^']*'|'pass_hash'     => '${h_esc}'|" "$cfg"

    # 明文补写 .credentials (先删旧的面板三行再追加，保持幂等)
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        sed -i '/^解封面板/d' "$CREDENTIALS_FILE" 2>/dev/null || true
    fi
    {
        echo "解封面板地址: https://${DOMAIN:-你的域名}/f2b/"
        echo "解封面板用户: admin"
        echo "解封面板密码: ${new_pass}"
    } >> "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true

    echo ""
    log "面板密码已重置"
    echo -e "  ${BOLD}用户:${NC} ${CYAN}admin${NC}"
    echo -e "  ${BOLD}密码:${NC} ${CYAN}${new_pass}${NC}"
    echo -e "  ${DIM}已写入 $CREDENTIALS_FILE${NC}"
    echo -e "  ${DIM}面板读取配置是实时的，无需重启容器，直接用新密码登录即可。${NC}"
}

# 只升级 fail2ban 面板页面代码 + 桥接脚本 + fail2ban 规则，保留现有登录密码与封禁数据。
# (--setup-waf 会重新生成密码；已部署环境拿新功能用这个)
cmd_update_f2b_panel() {
    step "${ICON_GEAR} 升级 fail2ban 面板 (保留账号密码)"
    [[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行"
    load_existing_env
    local root="$PROJECT_DIR/fail2ban-panel"
    [[ -f "$root/config/panel.php" ]] || error "未找到已安装的面板，请先运行 $0 --setup-waf"
    command -v fail2ban-client &>/dev/null || error "fail2ban 未安装，请先运行 $0 --setup-waf"
    detect_server_config
    # 封禁动作改用 ipset，老环境需补装
    install_fail2ban

    # 下面会就地改写正在运行的 nginx.conf / 站点配置 / compose。先整体打包备份，
    # 中途出错退出或新配置 nginx -t 不通过时自动还原，避免 nginx 下次重启时起不来导致全站中断
    local nginx_cfg_paths=(docker-compose.yml)
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_cfg_paths+=(volumes/nginx/config/nginx)
    else
        local p
        for p in volumes/nginx/nginx.conf volumes/nginx/waf-guard.conf volumes/nginx/conf.d; do
            [[ -e "$PROJECT_DIR/$p" ]] && nginx_cfg_paths+=("$p")
        done
    fi
    F2B_UPGRADE_BACKUP="$(mktemp /tmp/lnmp-nginx-backup.XXXXXX.tar)"
    tar -C "$PROJECT_DIR" -cf "$F2B_UPGRADE_BACKUP" "${nginx_cfg_paths[@]}" \
        || error "备份 nginx 配置失败，已中止 (未做任何修改)"
    F2B_UPGRADE_DONE=0
    trap '_f2b_upgrade_rollback' EXIT
    info "已备份当前 nginx 配置: $F2B_UPGRADE_BACKUP"

    _f2b_write_panel_files "$root" "__keep__" "" ""
    # 日志控制放在 fail2ban 规则之前: 先把超大的 access.log 截小，fail2ban 重载时就不用扫整个大文件
    setup_log_rotate
    bash "$PROJECT_DIR/log_rotate.sh" 2>/dev/null || true

    # nginx 层封禁 (geo 名单) + Cloudflare 真实 IP: 需重写主配置、WAF 片段与 compose 挂载
    setup_nginx_main_config
    setup_waf_guard
    setup_docker_compose

    # 清掉旧版「每 IP 一条」的 DROP 规则 (改用 ipset 后不再需要)。
    # 只匹配旧脚本生成的精确格式「-A DOCKER-USER -s <IP>/32 -j DROP」，
    # 带端口、协议等条件的规则 (用户自己加的) 不会被删
    local rule removed=0
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        # shellcheck disable=SC2086
        iptables ${rule/-A DOCKER-USER/-D DOCKER-USER} 2>/dev/null && removed=$((removed + 1))
    done < <(iptables -S DOCKER-USER 2>/dev/null | grep -E '^-A DOCKER-USER -s [0-9.]+(/32)? -j DROP$' || true)
    [[ $removed -gt 0 ]] && info "已清理旧版单 IP 封禁规则 $removed 条 (封禁已迁移到 ipset)"

    setup_fail2ban_config
    setup_f2b_bridge

    # 补上 /f2b/ 入口 (片段 + 主域名 include)。之前 --setup-waf 中途退出的环境会缺这两样
    _f2b_write_panel_inc

    # 应用新挂载 (f2b-banned.conf) 并检查 nginx 配置
    cd "$PROJECT_DIR" || error "无法进入项目目录"
    info "重建 nginx 容器以应用封禁名单挂载..."
    # 先用新 compose (已含新挂载) 起一个临时容器校验，通过后才替换正在运行的容器。
    # linuxserver 镜像的配置由 s6 初始化脚本准备，临时容器里直接跑 nginx -t 不可靠，只做下面的事后检查
    if [[ "$NGINX_TYPE" != "linuxserver" ]] \
       && ! docker compose run --rm --no-deps -T --entrypoint nginx nginx -t >/dev/null 2>&1; then
        warn "新 nginx 配置检查未通过，错误如下:"
        docker compose run --rm --no-deps -T --entrypoint nginx nginx -t 2>&1 | tail -5 || true
        error "已中止升级，配置将自动还原"
    fi
    docker compose up -d nginx
    sleep 3
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 || true
        log "nginx 配置检查通过"
    else
        warn "nginx 配置检查未通过，错误如下:"
        docker compose exec -T nginx nginx -t 2>&1 | tail -5 || true
        error "已中止升级，配置将自动还原"
    fi
    F2B_UPGRADE_DONE=1
    rm -f "$F2B_UPGRADE_BACKUP"
    trap - EXIT
    log "面板已升级，刷新浏览器即可 (IP 国家信息已用本地 GeoIP 库生成)"
}

# --update-f2b-panel 中途失败时还原 nginx 配置与 compose，并按旧配置重建 nginx 容器
_f2b_upgrade_rollback() {
    local rc=$?
    [[ "${F2B_UPGRADE_DONE:-1}" == "1" ]] && return
    [[ -f "${F2B_UPGRADE_BACKUP:-}" ]] || return
    trap - EXIT
    echo ""
    warn "升级未完成，正在还原 nginx 配置..."
    if tar -C "$PROJECT_DIR" -xf "$F2B_UPGRADE_BACKUP"; then
        (cd "$PROJECT_DIR" && docker compose up -d nginx >/dev/null 2>&1 \
            && docker compose exec -T nginx nginx -s reload >/dev/null 2>&1) || true
        rm -f "$F2B_UPGRADE_BACKUP"
        warn "已还原到升级前的 nginx 配置"
    else
        warn "自动还原失败，备份保留在: $F2B_UPGRADE_BACKUP (tar -C $PROJECT_DIR -xf 该文件 可手动还原)"
    fi
    exit "$rc"
}

# 将面板 include 注入主域名的 443 server 块 (幂等)
_inject_panel_include() {
    local inc_path="$1"
    local nginx_conf_dir main_conf
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
    fi
    [[ -d "$nginx_conf_dir" ]] || return 0

    # 定位主域名配置文件 (server_name 恰为主域名)
    # 末尾 || true: 找不到时 grep 返回 1，pipefail + set -e 会让整个脚本在这里直接退出
    # 匹配 "server_name 域名;" 或 "server_name 域名 www.域名;" 两种写法
    [[ -n "${DOMAIN:-}" ]] || { warn "DOMAIN 为空，面板入口未注入"; return 0; }
    # 只看含 listen 443 的文件，避免选中 80 跳转配置
    local f
    for f in "$nginx_conf_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        grep -q "listen.*443" "$f" 2>/dev/null || continue
        if grep -qE "server_name[[:space:]]+([^;]*[[:space:]])?${DOMAIN//./\\.}([[:space:]]|;)" "$f" 2>/dev/null; then
            main_conf="$f"; break
        fi
    done
    # 兜底: 安装时生成的主域名配置文件名固定为 01-<域名>.conf
    [[ -z "$main_conf" && -f "$nginx_conf_dir/01-${DOMAIN}.conf" ]] && main_conf="$nginx_conf_dir/01-${DOMAIN}.conf"
    if [[ -z "$main_conf" ]]; then
        warn "在 $nginx_conf_dir 中未找到主域名 ${DOMAIN} 的 HTTPS 配置，面板入口 /f2b/ 未注入"
        warn "可手动在主域名 443 server 块内加一行: include ${inc_path};  然后重载 nginx"
        return 0
    fi

    if grep -q "f2b-panel.inc" "$main_conf" 2>/dev/null; then
        log "面板入口已存在: $(basename "$main_conf")"
        return 0
    fi
    # 只在第一个 "listen 443" 行后插入一次，确保落在 HTTPS server 块里；
    # 用 sed /^server {/a 会插进文件里每一个 server 块 (含 80 跳转块)，location 重复导致 nginx 报错
    awk -v inc="    include ${inc_path};" '
        !done && /listen/ && /443/ { print; print inc; done=1; next }
        { print }
    ' "$main_conf" > "$main_conf.tmp" && cat "$main_conf.tmp" > "$main_conf"
    rm -f "$main_conf.tmp"
    if grep -q "f2b-panel.inc" "$main_conf" 2>/dev/null; then
        log "面板入口 /f2b/ 已注入: $(basename "$main_conf")"
    else
        warn "面板入口注入失败: $(basename "$main_conf") 中没有 listen 443 行"
    fi
}

# 命令行: 查看封禁列表
cmd_f2b_status() {
    if ! command -v fail2ban-client &>/dev/null; then
        error "fail2ban 未安装，请先运行 $0 --setup-waf"
    fi
    step "${ICON_LOCK} fail2ban 封禁状态"
    echo -e "  ${BOLD}网站 (lnmp-nginx):${NC}"
    fail2ban-client status lnmp-nginx 2>/dev/null || error "jail lnmp-nginx 不存在，请先运行 $0 --setup-waf"
    if fail2ban-client status sshd &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}SSH (sshd):${NC}"
        fail2ban-client status sshd
    fi
}

# 命令行: 解封指定 IP
cmd_f2b_unban() {
    local ip="$1"
    [[ -z "$ip" ]] && error "用法: $0 --f2b-unban <IP>"
    if ! command -v fail2ban-client &>/dev/null; then
        error "fail2ban 未安装"
    fi
    # 网站和 SSH 两个 jail 都尝试解封
    local ok=0 jail
    for jail in lnmp-nginx sshd; do
        fail2ban-client set "$jail" unbanip "$ip" &>/dev/null && { log "已从 $jail 解封: $ip"; ok=1; }
    done
    [[ $ok -eq 1 ]] || warn "解封失败 (该 IP 可能未被封禁): $ip"
}

# 命令行: 手动封禁指定 IP
cmd_f2b_ban() {
    local ip="$1"
    [[ -z "$ip" ]] && error "用法: $0 --f2b-ban <IP>"
    if ! command -v fail2ban-client &>/dev/null; then
        error "fail2ban 未安装"
    fi
    if fail2ban-client set lnmp-nginx banip "$ip" 2>/dev/null; then
        log "已封禁: $ip"
    else
        warn "封禁失败: $ip"
    fi
}

# 一键为已部署环境装齐 WAF + fail2ban + 面板 (幂等)
cmd_setup_waf() {
    show_banner
    [[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行"
    load_existing_env
    detect_server_config

    step "${ICON_LOCK} 为现有部署启用 WAF + fail2ban"
    echo -e "  ${DIM}将执行:${NC}"
    echo -e "    ${DIM}- 重写主 nginx.conf (加 UA/路径黑名单 map) 与 docker-compose.yml (加日志/WAF挂载)${NC}"
    echo -e "    ${DIM}- 生成 waf-guard.conf 并注入各站点 server 块${NC}"
    echo -e "    ${DIM}- 安装并配置 fail2ban (封禁到 DOCKER-USER 链)${NC}"
    echo -e "    ${DIM}- 创建网页解封面板 + 宿主机桥接任务${NC}"
    echo -e "  ${GREEN}保留不动:${NC} 数据库 / 证书 / 站点文件"
    echo ""
    printf "${GREEN}  确认继续? [y/N]: ${NC}"
    IFS= read -r confirm || confirm=""
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { info "已取消"; return 0; }

    # 1) 重写主配置 + compose (带入新的 map 与挂载)
    setup_nginx_main_config
    setup_docker_compose
    # 2) WAF 片段 + 注入 include 到已有站点
    setup_waf_guard
    inject_waf_include
    # 3) fail2ban
    install_fail2ban
    setup_fail2ban_config
    # 4) 面板 + 桥接
    setup_f2b_panel
    setup_f2b_bridge

    # 5) 重建容器 (应用新挂载) 并重载
    cd "$PROJECT_DIR" || error "无法进入项目目录"
    info "重建 nginx/php 容器以应用新挂载..."
    docker compose up -d
    info "重载 Nginx..."
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        docker compose exec -T nginx nginx -s reload 2>/dev/null || docker compose restart nginx
    else
        warn "Nginx 配置测试未通过，错误如下:"
        docker compose exec -T nginx nginx -t 2>&1 | tail -5 || true
    fi

    # PHP 容器已就绪，回填面板密码哈希
    _f2b_finalize_hash

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ${ICON_OK} ${BOLD}WAF + fail2ban 已启用！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _print_f2b_summary
}

# 打印面板访问信息 (安装/升级结束时调用)
_print_f2b_summary() {
    echo -e "  ${ICON_LOCK} ${BOLD}fail2ban 面板:${NC}"
    echo -e "     地址: ${CYAN}https://$DOMAIN/f2b/${NC}  ${DIM}(自带登录页)${NC}"
    if [[ -n "${F2B_PANEL_USER:-}" && -n "${F2B_PANEL_PASS:-}" ]]; then
        echo -e "     用户: ${CYAN}${F2B_PANEL_USER}${NC}"
        echo -e "     密码: ${CYAN}${F2B_PANEL_PASS}${NC}  ${DIM}(已写入 $CREDENTIALS_FILE)${NC}"
    else
        echo -e "     ${DIM}凭据见 $CREDENTIALS_FILE${NC}"
    fi
    echo ""
    echo -e "  ${ICON_GEAR} ${BOLD}命令行管理:${NC}"
    echo -e "     $0 --f2b-status        查看封禁 IP"
    echo -e "     $0 --f2b-unban <IP>    解封"
    echo -e "     $0 --f2b-ban <IP>      手动封禁"
    echo ""
    echo -e "  ${YELLOW}${ICON_WARN} 提示:${NC} 面板全网可访问仅靠密码保护；如需更严，可在"
    echo -e "     ${DIM}f2b-panel.inc 中启用 allow <你的IP>; deny all;${NC}"
    echo -e "  ${YELLOW}${ICON_WARN} 提示:${NC} iptables 规则重启宿主机后丢失，长期建议安装 iptables-persistent"
    echo ""
}

# ======================== 凭据和文档 ========================
save_credentials() {
    step "${ICON_LOCK} 保存凭据信息"
    
    cat > "$CREDENTIALS_FILE" << EOFCRED
# LNMP 部署凭据 - 请妥善保管！
# 生成时间: $(date)
# ==========================================
域名: $DOMAIN
子域名: ${SUBDOMAINS[*]}
MySQL Root 密码: $MYSQL_ROOT_PASS
MySQL 数据库: $MYSQL_DB
Redis 密码: $REDIS_PASSWORD
PHP 版本: $PHP_VERSION
# ==========================================
EOFCRED
    # 面板凭据可能已由 setup_f2b_panel 生成；此处一并写入 (在 cat> 覆盖之后重新追加)
    if [[ -n "${F2B_PANEL_USER:-}" && -n "${F2B_PANEL_PASS:-}" ]]; then
        {
            echo "解封面板地址: https://$DOMAIN/f2b/"
            echo "解封面板用户: ${F2B_PANEL_USER}"
            echo "解封面板密码: ${F2B_PANEL_PASS}"
        } >> "$CREDENTIALS_FILE"
    fi
    chmod 600 "$CREDENTIALS_FILE"
    
    # README
    cat > "$README_FILE" << EOFREADME
# LNMP Docker 部署

## 目录结构
\`\`\`
$PROJECT_DIR/
├── docker-compose.yml
├── volumes/
│   ├── nginx/config/    # Nginx 配置 (linuxserver/nginx)
│   │   └── nginx/
│   │       ├── nginx.conf       # 主配置文件
│   │       └── site-confs/      # 虚拟主机配置
│   ├── php/www/         # 网站文件
│   ├── mysql/
│   │   ├── data/        # 数据库数据文件
│   │   └── conf.d/      # 数据库配置
│   └── redis/           # Redis 数据
├── certbot/             # SSL 证书
└── backups/             # 备份文件
\`\`\`

## 常用管理命令 (脚本封装)
> 下面的 \`$0\` 即本部署脚本 (通常是 \`$PROJECT_DIR/deploy.sh\`)
\`\`\`bash
# ---- 服务管理 ----
$0 --status                # 查看所有服务运行状态
$0 --restart               # 重启所有服务
$0 --stop                  # 停止所有服务
$0 --logs                  # 查看全部日志 (实时)
$0 --logs nginx            # 查看指定服务日志 (nginx/php/mysql/redis)
$0 --health                # 健康检查
$0 --info                  # 显示当前配置信息

# ---- 备份 / 证书 ----
$0 --backup                # 立即执行一次备份
$0 --renew                 # 续期已有 SSL 证书
$0 --cert                  # 单独申请 / 重新申请 SSL 证书

# ---- 域名 / 代理 ----
$0 --add-subdomain         # 添加新子域名
$0 --add-proxy             # 添加反向代理到宿主机服务

# ---- 重建 / 维护 ----
$0 --rebuild-nginx         # 重建 Nginx 镜像 (可切换类型)
$0 --rebuild-php           # 重建 PHP 镜像 (可选择版本)
$0 --rebuild-mysql         # 重建 MySQL/MariaDB (可选择版本, 不删数据)
$0 --reset-mysql-password  # 重置 MySQL/MariaDB root 密码 (不影响数据)
$0 --reconfig              # 从 .env 重新生成配置并重建 (不动数据)
$0 --cleanup               # 清理未使用的 Docker 资源
$0 --upgrade               # 升级脚本自身到最新版本
\`\`\`

## Docker Compose 常用命令
> 需先进入项目目录: \`cd $PROJECT_DIR\`
\`\`\`bash
docker compose ps                        # 查看容器状态
docker compose up -d                     # 启动 / 更新所有服务
docker compose down                      # 停止并移除容器 (数据卷保留)
docker compose restart mysql             # 重启单个服务
docker compose logs -f --tail=100 php    # 跟踪某个服务的日志
docker compose exec php sh               # 进入 PHP 容器 shell
\`\`\`

## 数据库操作 (MySQL / MariaDB)
> root 密码见 \`.credentials\` 文件。若使用的是 MySQL 8.0 镜像, 请把下列 \`mariadb\` / \`mariadb-dump\` 换成 \`mysql\` / \`mysqldump\`。
\`\`\`bash
# 进入数据库命令行 (回车后输入 root 密码)
docker compose exec mysql mariadb -uroot -p

# 创建数据库
docker compose exec mysql mariadb -uroot -p -e "CREATE DATABASE dbname CHARACTER SET utf8mb4;"

# 创建用户并授权
docker compose exec mysql mariadb -uroot -p -e "CREATE USER 'user'@'%' IDENTIFIED BY 'password'; GRANT ALL ON dbname.* TO 'user'@'%'; FLUSH PRIVILEGES;"

# 查看所有数据库
docker compose exec mysql mariadb -uroot -p -e "SHOW DATABASES;"

# 备份 / 恢复数据库 (-T 重定向时无法交互输密码，直接用容器内的 root 密码环境变量)
docker compose exec -T mysql sh -c 'exec mariadb-dump -uroot -p"\$MYSQL_ROOT_PASSWORD" --single-transaction dbname' > backup.sql
docker compose exec -T mysql sh -c 'exec mariadb -uroot -p"\$MYSQL_ROOT_PASSWORD" dbname' < backup.sql

# 忘记 / 需要重置 root 密码 (不影响数据):
$0 --reset-mysql-password
\`\`\`

## 迁移到新环境 / 从全库备份恢复 (重要)
> ⚠️ 全库备份 (\`--all-databases\`, 即自动备份 \`db_*.sql\`) 包含 \`mysql\` 系统库, 账号权限表 \`user\` 就在其中。整体导入新环境会覆盖新环境的 \`mysql.user\`, 导致 root 密码与 \`.credentials\` 记录不一致、登录失败、健康检查异常。
>
> **推荐做法: 只导业务库, 不碰 \`mysql\` 系统库** (新环境 root 密码保持自身不变, 最稳妥)。
\`\`\`bash
# 1. 查看备份里有哪些库 (排除 mysql/sys/information_schema/performance_schema 系统库)
grep -E "^-- Current Database:|^CREATE DATABASE" backups/db_YYYYmmdd_HHMMSS.sql

# 2. 先在新环境建好各业务库
#    (--one-database 靠 USE 语句过滤, 而 CREATE DATABASE 行在 USE 之前会被过滤掉, 故需手动建)
docker compose exec mysql mariadb -uroot -p -e \\
  "CREATE DATABASE IF NOT EXISTS dbname CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# 3. 逐个导入业务库 (--one-database 只作用于该库, mysql 系统库那段被忽略, user 表不受影响)
docker compose exec -T mysql sh -c 'exec mariadb -uroot -p"\$MYSQL_ROOT_PASSWORD" --one-database dbname' < backups/db_YYYYmmdd_HHMMSS.sql

# 4. 验证各库表数量
docker compose exec mysql mariadb -uroot -p -e \\
  "SELECT table_schema '库', COUNT(*) '表数' FROM information_schema.tables WHERE table_schema='dbname';"

# 5. 因未导入 mysql.user, 需按各应用配置里的账号重建数据库用户 (账号/密码与应用配置一致即无需改应用)
docker compose exec mysql mariadb -uroot -p -e \\
  "CREATE USER IF NOT EXISTS 'user'@'%' IDENTIFIED BY 'password'; GRANT ALL ON dbname.* TO 'user'@'%'; FLUSH PRIVILEGES;"
\`\`\`
> 若确需整库全导 (含 user 表): 导入后新环境 root 密码会变成旧环境的, 必须把旧环境的 \`.credentials\` 与 \`.env\` 中 MYSQL_ROOT_PASS 一并同步到新环境, 再 \`docker compose down && docker compose up -d\`; 若密码错乱连不上, 用 \`$0 --reset-mysql-password\` 重置 (不影响数据)。最后把旧环境 \`volumes/php/www/\` 对应站点目录拷到新环境同路径。

## Redis 操作
> 密码见 \`.credentials\` 文件, 把下面的 '你的Redis密码' 替换为实际密码
\`\`\`bash
docker compose exec redis redis-cli -a '你的Redis密码'             # 进入 Redis
docker compose exec redis redis-cli -a '你的Redis密码' KEYS '*'    # 查看所有 key
docker compose exec redis redis-cli -a '你的Redis密码' FLUSHALL    # 清空缓存
docker compose exec redis redis-cli -a '你的Redis密码' INFO memory # 查看内存使用
\`\`\`

## 网站目录
- 主域名: volumes/php/www/$DOMAIN/
$(for sub in "${SUBDOMAINS[@]}"; do echo "- ${sub}: volumes/php/www/${sub}.${DOMAIN}/"; done)

## 凭据
详见 .credentials 文件
EOFREADME
    log "凭据和文档已保存"
}

# ======================== 服务管理命令 ========================
cmd_status() {
    step "${ICON_INFO} 服务状态"
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"
    docker compose ps
}

cmd_restart() {
    step "${ICON_GEAR} 重启服务"
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"
    docker compose restart
    log "服务已重启"
}

cmd_stop() {
    step "${ICON_WARN} 停止服务"
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"
    docker compose down
    log "服务已停止"
}

cmd_logs() {
    local service=${1:-}
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"
    if [[ -n "$service" ]]; then
        docker compose logs -f --tail=100 "$service"
    else
        docker compose logs -f --tail=50
    fi
}

cmd_info() {
    step "${ICON_INFO} 当前配置"
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        error "配置文件不存在，请先运行完整安装"
    fi
    source "$PROJECT_DIR/.env"
    echo ""
    echo -e "  ${BOLD}域名:${NC}        $DOMAIN"
    echo -e "  ${BOLD}PHP 版本:${NC}    $PHP_VERSION"
    echo -e "  ${BOLD}数据库:${NC}      $MYSQL_DB"
    echo -e "  ${BOLD}项目目录:${NC}    $PROJECT_DIR"
    echo ""
    
    # 显示 phpMyAdmin 状态
    if docker compose -f "$PROJECT_DIR/docker-compose.yml" ps phpmyadmin 2>/dev/null | grep -q "Up"; then
        echo -e "  ${BOLD}phpMyAdmin:${NC}  http://服务器IP:8080"
    fi
    echo ""
    
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        echo -e "  ${DIM}凭据文件: $CREDENTIALS_FILE${NC}"
    fi
}

cmd_health() {
    step "${ICON_INFO} 健康检查"
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"
    
    local all_ok=true
    
    echo ""
    echo -e "  ${BOLD}服务状态:${NC}"
    for svc in nginx php mysql redis; do
        local status=$(docker compose ps -q $svc 2>/dev/null)
        if [[ -n "$status" ]] && docker ps -q --no-trunc | grep -q "$status"; then
            echo -e "  ${GREEN}${ICON_OK}${NC} $svc: 运行中"
        else
            echo -e "  ${RED}${ICON_FAIL}${NC} $svc: 未运行"
            all_ok=false
        fi
    done
    
    # 检查端口
    echo ""
    echo -e "  ${BOLD}端口状态:${NC}"
    for port in 80 443; do
        if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo -e "  ${GREEN}${ICON_OK}${NC} 端口 $port: 已监听"
        else
            echo -e "  ${RED}${ICON_FAIL}${NC} 端口 $port: 未监听"
            all_ok=false
        fi
    done
    
    # 检查 SSL 证书
    echo ""
    echo -e "  ${BOLD}SSL 证书:${NC}"
    source "$PROJECT_DIR/.env" 2>/dev/null || true
    local cert_file="$PROJECT_DIR/certbot/conf/live/$DOMAIN/fullchain.pem"
    if [[ -f "$cert_file" ]]; then
        local expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
        local now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        
        if [[ $days_left -gt 30 ]]; then
            echo -e "  ${GREEN}${ICON_OK}${NC} 证书有效: 剩余 $days_left 天"
        elif [[ $days_left -gt 7 ]]; then
            echo -e "  ${YELLOW}${ICON_WARN}${NC} 证书即将到期: 剩余 $days_left 天"
        elif [[ $days_left -gt 0 ]]; then
            echo -e "  ${RED}${ICON_FAIL}${NC} 证书即将到期: 仅剩 $days_left 天！"
            all_ok=false
        else
            echo -e "  ${RED}${ICON_FAIL}${NC} 证书已过期！"
            all_ok=false
        fi
    else
        echo -e "  ${YELLOW}${ICON_WARN}${NC} 未找到 SSL 证书"
    fi
    
    # 磁盘空间
    echo ""
    echo -e "  ${BOLD}磁盘空间:${NC}"
    local disk_usage=$(df -h "$PROJECT_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
    local disk_avail=$(df -h "$PROJECT_DIR" | awk 'NR==2 {print $4}')
    if [[ $disk_usage -lt 80 ]]; then
        echo -e "  ${GREEN}${ICON_OK}${NC} 磁盘使用: ${disk_usage}% (可用: $disk_avail)"
    elif [[ $disk_usage -lt 90 ]]; then
        echo -e "  ${YELLOW}${ICON_WARN}${NC} 磁盘使用: ${disk_usage}% (可用: $disk_avail)"
    else
        echo -e "  ${RED}${ICON_FAIL}${NC} 磁盘使用: ${disk_usage}% (可用: $disk_avail)"
        all_ok=false
    fi
    
    echo ""
    if $all_ok; then
        log "所有检查通过"
    else
        warn "部分检查未通过，请关注上述问题"
    fi
}

cmd_add_subdomain() {
    step "${ICON_GLOBE} 添加子域名"

    load_existing_env

    printf "${GREEN}  请输入新子域名 (不含主域名): ${NC}"
    IFS= read -r new_sub || new_sub=""
    [[ -z "$new_sub" ]] && error "子域名不能为空"
    
    local sub_dir="$PROJECT_DIR/volumes/php/www/${new_sub}.${DOMAIN}"
    mkdir -p "$sub_dir"
    
    # Determine config directory based on NGINX_TYPE
    local nginx_conf_dir waf_include
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
        waf_include="    include /config/nginx/waf-guard.conf;"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
        waf_include="    include /etc/nginx/waf-guard.conf;"
    fi

    # 重复检测: 避免同一子域名被添加两次产生冲突的 server_name
    if grep -rqsE "server_name[[:space:]]+${new_sub}\.${DOMAIN};" "$nginx_conf_dir/" 2>/dev/null; then
        error "子域名 ${new_sub}.${DOMAIN} 已存在配置，请勿重复添加"
    fi

    local ssl_cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    # 取现有配置文件的最大数字前缀 +1，避免用文件总数推算时因删除产生空洞而撞名覆盖
    local existing_max
    existing_max=$(ls -1 "$nginx_conf_dir/" 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -1) || true
    existing_max=${existing_max:-0}
    local config_num=$(( 10#$existing_max + 1 ))
    local config_prefix
    config_prefix=$(printf '%02d' "$config_num")
    local new_conf="$nginx_conf_dir/${config_prefix}-${new_sub}.conf"

    cat > "$new_conf" << EOFNEWSUB
server {
    listen 443 ssl;
    listen 443 quic;
    http2 on;
    http3 on;
    server_name ${new_sub}.${DOMAIN};
    root /var/www/html/${new_sub}.${DOMAIN};
    index index.php index.html;

    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;

${waf_include}

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}
EOFNEWSUB

    # 创建欢迎页
    cat > "$sub_dir/index.html" << EOFHTML
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>${new_sub}.${DOMAIN}</title>
<style>body{font-family:system-ui;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;text-align:center}</style>
</head><body><div><h1>🚀 ${new_sub}.${DOMAIN}</h1><p>New subdomain ready!</p></div></body></html>
EOFHTML

    # 重载 Nginx: 先测试配置，失败则回滚新增的配置文件，避免坏配置留在盘上
    cd "$PROJECT_DIR"
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        docker compose exec -T nginx nginx -s reload
    else
        rm -f "$new_conf"
        error "Nginx 配置测试失败，已回滚新增的子域名配置"
    fi

    log "子域名 ${new_sub}.${DOMAIN} 添加成功"
    info "网站目录: $sub_dir"
    warn "如果使用单域名证书，需要重新申请证书以包含新子域名"
}

# 删除子域名: 移除其 nginx 配置并把站点文件归档到 deleted-sites/ (不硬删，可找回)
cmd_del_subdomain() {
    step "${ICON_GLOBE} 删除子域名"

    load_existing_env

    local nginx_conf_dir
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
    fi

    # 列出现有子域名 (排除主域名本身)
    local -a subs=()
    local f sn
    for f in "$nginx_conf_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        # 抓 server_name，忽略 "_" 默认 server 和主域名
        while IFS= read -r sn; do
            [[ "$sn" == "_" || "$sn" == "$DOMAIN" ]] && continue
            [[ "$sn" == *".$DOMAIN" ]] && subs+=("$sn")
        done < <(grep -hoE "server_name[[:space:]]+[^;]+;" "$f" 2>/dev/null \
                   | sed -E 's/server_name[[:space:]]+//; s/;//' | tr ' ' '\n')
    done

    if [[ ${#subs[@]} -eq 0 ]]; then
        warn "未发现可删除的子域名"
        return 0
    fi

    # 确定目标子域名: 命令行参数优先，否则交互选择
    local target="$1"
    if [[ -n "$target" ]]; then
        # 允许传 "api" 或 "api.example.com"
        [[ "$target" != *".$DOMAIN" ]] && target="${target}.${DOMAIN}"
        local found=0 s
        for s in "${subs[@]}"; do [[ "$s" == "$target" ]] && found=1; done
        [[ $found -eq 0 ]] && error "未找到子域名配置: $target"
    else
        echo ""
        echo -e "  ${BOLD}现有子域名:${NC}"
        local i=1 s
        for s in "${subs[@]}"; do
            echo -e "  ${CYAN}$i)${NC} $s"
            i=$((i + 1))
        done
        echo ""
        printf "${GREEN}  请选择要删除的编号 [1-$((i-1))]: ${NC}"
        IFS= read -r choice || choice=""
        [[ ! "$choice" =~ ^[0-9]+$ ]] && error "无效选择"
        [[ "$choice" -lt 1 || "$choice" -ge $i ]] && error "编号超出范围"
        target="${subs[$((choice-1))]}"
    fi

    echo ""
    warn "将删除子域名: ${target}"
    echo -e "  ${DIM}- 移除其 nginx 配置文件${NC}"
    echo -e "  ${DIM}- 站点文件归档到 deleted-sites/ (不硬删)${NC}"
    printf "${YELLOW}  确认删除? [y/N]: ${NC}"
    IFS= read -r confirm || confirm=""
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { info "已取消"; return 0; }

    # 1) 找到并备份该子域名的 conf 文件 (按 server_name 精确匹配)
    local conf_file
    conf_file=$(grep -rlE "server_name[[:space:]]+${target};" "$nginx_conf_dir"/*.conf 2>/dev/null | head -1) || true
    local archive_dir="$PROJECT_DIR/deleted-sites/${target}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$archive_dir"
    if [[ -n "$conf_file" && -f "$conf_file" ]]; then
        mv "$conf_file" "$archive_dir/$(basename "$conf_file")"
        log "已移除配置: $(basename "$conf_file")"
    else
        warn "未找到对应 nginx 配置文件 (可能已删除)"
    fi

    # 2) 归档站点文件
    local site_dir="$PROJECT_DIR/volumes/php/www/${target}"
    if [[ -d "$site_dir" ]]; then
        mv "$site_dir" "$archive_dir/www" 2>/dev/null || cp -r "$site_dir" "$archive_dir/www"
        rm -rf "$site_dir" 2>/dev/null || true
        log "站点文件已归档到: $archive_dir/www"
    fi

    # 3) 测试并重载 nginx
    cd "$PROJECT_DIR"
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        docker compose exec -T nginx nginx -s reload 2>/dev/null || docker compose restart nginx
        log "子域名 ${target} 已删除，Nginx 已重载"
    else
        warn "Nginx 配置测试失败，请手动检查: docker compose exec nginx nginx -t"
    fi

    info "归档目录: $archive_dir (确认无需找回后可手动删除)"
    warn "DNS 解析记录需你自行在域名商处删除"
}

cmd_add_proxy() {
    step "${ICON_GLOBE} 添加反向代理配置"

    load_existing_env
    
    echo ""
    echo -e "  ${BOLD}反向代理配置向导${NC}"
    echo -e "  ${DIM}用于将 Nginx 请求转发到宿主机上运行的服务${NC}"
    echo -e "  ${DIM}容器通过 host.docker.internal 访问宿主机${NC}"
    echo ""
    
    printf "${GREEN}  请输入子域名 (不含主域名，如 api): ${NC}"
    IFS= read -r proxy_sub || proxy_sub=""
    [[ -z "$proxy_sub" ]] && error "子域名不能为空"
    
    printf "${GREEN}  请输入宿主机端口 (如 3000): ${NC}"
    IFS= read -r host_port || host_port=""
    [[ -z "$host_port" ]] && error "端口不能为空"
    
    if ! [[ "$host_port" =~ ^[0-9]+$ ]] || [[ "$host_port" -lt 1 ]] || [[ "$host_port" -gt 65535 ]]; then
        error "无效的端口号: $host_port"
    fi
    
    echo ""
    echo -e "  ${CYAN}代理协议:${NC}"
    echo -e "  ${CYAN}1)${NC} HTTP (默认)"
    echo -e "  ${CYAN}2)${NC} HTTPS"
    printf "${GREEN}  请选择 [1-2] (默认 1): ${NC}"
    IFS= read -r proto_choice || proto_choice="1"
    
    local upstream_proto="http"
    [[ "$proto_choice" == "2" ]] && upstream_proto="https"
    
    local nginx_conf_dir
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
    fi
    
    # 重复检测: 避免同一子域名反代被添加两次
    if grep -rqsE "server_name[[:space:]]+${proxy_sub}\.${DOMAIN};" "$nginx_conf_dir/" 2>/dev/null; then
        error "子域名 ${proxy_sub}.${DOMAIN} 已存在配置，请勿重复添加"
    fi

    local ssl_cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    # 取现有配置文件的最大数字前缀 +1，避免用文件总数推算导致撞名覆盖
    local existing_max
    existing_max=$(ls -1 "$nginx_conf_dir/" 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -1) || true
    existing_max=${existing_max:-0}
    local config_num=$(( 10#$existing_max + 1 ))
    local config_prefix
    config_prefix=$(printf '%02d' "$config_num")
    local new_conf="$nginx_conf_dir/${config_prefix}-proxy-${proxy_sub}.conf"

    cat > "$new_conf" << EOFPROXY
# 反向代理: ${proxy_sub}.${DOMAIN} -> host.docker.internal:${host_port}
upstream ${proxy_sub}_backend {
    server host.docker.internal:${host_port};
    keepalive 32;
}

server {
    listen 443 ssl;
    listen 443 quic;
    http2 on;
    http3 on;
    server_name ${proxy_sub}.${DOMAIN};

    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    location / {
        proxy_pass ${upstream_proto}://${proxy_sub}_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    listen 80;
    server_name ${proxy_sub}.${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOFPROXY

    cd "$PROJECT_DIR"
    if docker compose exec -T nginx nginx -t 2>/dev/null; then
        docker compose exec -T nginx nginx -s reload
        log "反向代理配置成功: ${proxy_sub}.${DOMAIN} -> host:${host_port}"
    else
        rm -f "$new_conf"
        docker compose exec -T nginx nginx -t || true
        error "Nginx 配置测试失败，已回滚新增的反向代理配置"
    fi
    
    echo ""
    echo -e "  ${BOLD}配置详情:${NC}"
    echo -e "    访问地址: https://${proxy_sub}.${DOMAIN}"
    echo -e "    代理目标: ${upstream_proto}://host.docker.internal:${host_port}"
    echo -e "    配置文件: $new_conf"
    echo ""
    warn "请确保宿主机服务监听在 0.0.0.0:${host_port} 而非 127.0.0.1:${host_port}"
    info "如使用通配符证书，代理将立即生效；否则需重新申请证书"
}

cmd_rebuild_nginx() {
    step "${ICON_GEAR} 重新构建 Nginx 镜像"

    load_existing_env
    
    local current_type=${NGINX_TYPE:-official}
    echo ""
    echo -e "  ${BOLD}当前 Nginx 类型:${NC} ${CYAN}$current_type${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} 使用当前类型重新构建/拉取"
    echo -e "  ${CYAN}2)${NC} 切换到其他 Nginx 类型"
    echo -e "  ${CYAN}0)${NC} 取消"
    echo ""
    printf "${GREEN}  请选择 [0-2]: ${NC}"
    IFS= read -r rebuild_choice || rebuild_choice=""
    
    case "$rebuild_choice" in
        0) info "操作已取消"; return 0 ;;
        2)
            echo ""
            echo -e "  ${CYAN}1)${NC} 官方 Nginx + GeoIP2 ${GREEN}← 推荐${NC}"
            echo -e "  ${CYAN}2)${NC} LinuxServer Nginx"
            echo -e "  ${CYAN}3)${NC} 官方 Nginx 标准版"
            printf "${GREEN}  请选择 [1-3]: ${NC}"
            IFS= read -r type_choice || type_choice=""
            case "$type_choice" in
                1) NGINX_TYPE="official" ;;
                2) NGINX_TYPE="linuxserver" ;;
                3) NGINX_TYPE="standard" ;;
                *) NGINX_TYPE="$current_type" ;;
            esac
            # official 与 standard 共用 volumes/nginx/conf.d 等目录，可以互切；
            # linuxserver 用 volumes/nginx/config/ 下另一套目录，站点配置、证书引用、WAF 片段
            # 都不会自动迁移，切换后网站会全部打不开 —— 不支持在线切换
            if [[ "$NGINX_TYPE" != "$current_type" && ( "$NGINX_TYPE" == "linuxserver" || "$current_type" == "linuxserver" ) ]]; then
                warn "不支持在 linuxserver 与 official/standard 之间切换: 两者站点配置目录不同，切换后网站会打不开"
                info "如需切换，请备份网站与数据库后重新安装"
                return 0
            fi
            if [[ "$NGINX_TYPE" != "$current_type" ]]; then
                if [[ -f "$PROGRESS_FILE" ]]; then
                    if grep -q "^NGINX_TYPE=" "$PROGRESS_FILE"; then
                        sed -i "s/^NGINX_TYPE=.*/NGINX_TYPE=$NGINX_TYPE/" "$PROGRESS_FILE" 2>/dev/null || \
                        sed -i '' "s/^NGINX_TYPE=.*/NGINX_TYPE=$NGINX_TYPE/" "$PROGRESS_FILE"
                    else
                        echo "NGINX_TYPE=$NGINX_TYPE" >> "$PROGRESS_FILE"
                    fi
                fi
                log "Nginx 类型已更新为: $NGINX_TYPE"
                setup_directories
                setup_nginx_main_config
                setup_waf_guard
                [[ "$NGINX_TYPE" == "official" ]] && setup_nginx_dockerfile
                setup_docker_compose
            fi
            ;;
        1|*) ;; # 使用当前类型
    esac
    
    cd "$PROJECT_DIR"
    info "停止 Nginx 容器..."
    docker compose stop nginx
    docker compose rm -f nginx 2>/dev/null || true
    
    case "$NGINX_TYPE" in
        official)
            docker images -q "lnmp-nginx-geoip2:*" 2>/dev/null | xargs -r docker rmi 2>/dev/null || true
            info "构建 Nginx + GeoIP2 镜像..."
            docker compose build --no-cache nginx
            ;;
        linuxserver)
            info "拉取 LinuxServer Nginx 镜像..."
            docker pull linuxserver/nginx:latest
            ;;
        standard)
            info "拉取官方 Nginx Alpine 镜像..."
            docker pull nginx:alpine
            ;;
    esac
    
    info "启动 Nginx 容器..."
    docker compose up -d nginx
    sleep 3
    
    if docker compose ps nginx | grep -q "Up"; then
        log "Nginx 重建完成！"
        docker compose exec -T nginx nginx -v 2>/dev/null || echo "  (无法获取版本)"
    else
        error "Nginx 容器启动失败，请检查日志: docker compose logs nginx"
    fi
}

cmd_rebuild_php() {
    step "${ICON_GEAR} 重新构建 PHP 镜像"
    
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        error "请先完成初始安装"
    fi
    source "$PROJECT_DIR/.env"
    
    local current_version=${PHP_VERSION:-8.2}
    echo ""
    echo -e "  ${BOLD}当前 PHP 版本:${NC} ${CYAN}$current_version${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} 使用当前版本重新构建 (PHP $current_version)"
    echo -e "  ${CYAN}2)${NC} 选择新版本构建"
    echo -e "  ${CYAN}0)${NC} 取消"
    echo ""
    printf "${GREEN}  请选择 [0-2]: ${NC}"
    IFS= read -r rebuild_choice || rebuild_choice=""
    
    case "$rebuild_choice" in
        0)
            info "操作已取消"
            return 0
            ;;
        1)
            # 使用当前版本
            ;;
        2)
            echo ""
            echo -e "  ${BOLD}选择 PHP 版本:${NC}"
            echo -e "  ${CYAN}1)${NC} PHP 7.4  ${DIM}(旧版本，兼容性好)${NC}"
            echo -e "  ${CYAN}2)${NC} PHP 8.0"
            echo -e "  ${CYAN}3)${NC} PHP 8.1"
            echo -e "  ${CYAN}4)${NC} PHP 8.2  ${GREEN}← 推荐${NC}"
            echo -e "  ${CYAN}5)${NC} PHP 8.3"
            echo -e "  ${CYAN}6)${NC} PHP 8.4  ${DIM}(最新版本)${NC}"
            echo -e "  ${CYAN}7)${NC} 自定义版本"
            echo ""
            printf "${GREEN}  请选择 [1-7]: ${NC}"
            IFS= read -r ver_choice || ver_choice=""
            
            case "$ver_choice" in
                1) PHP_VERSION="7.4" ;;
                2) PHP_VERSION="8.0" ;;
                3) PHP_VERSION="8.1" ;;
                4) PHP_VERSION="8.2" ;;
                5) PHP_VERSION="8.3" ;;
                6) PHP_VERSION="8.4" ;;
                7)
                    printf "${GREEN}  请输入自定义版本号 (如 8.2): ${NC}"
                    IFS= read -r custom_ver || custom_ver=""
                    PHP_VERSION="${custom_ver:-8.2}"
                    ;;
                *)
                    warn "无效选择，使用当前版本"
                    PHP_VERSION="$current_version"
                    ;;
            esac
            
            # 更新 .env 文件中的版本 (cross-platform sed)
            if [[ "$PHP_VERSION" != "$current_version" ]]; then
                if [[ "$(uname)" == "Darwin" ]]; then
                    sed -i '' "s/^PHP_VERSION=.*/PHP_VERSION=$PHP_VERSION/" "$PROJECT_DIR/.env"
                else
                    sed -i "s/^PHP_VERSION=.*/PHP_VERSION=$PHP_VERSION/" "$PROJECT_DIR/.env"
                fi
                log "PHP 版本已更新为: $PHP_VERSION"
            fi
            ;;
        *)
            info "操作已取消"
            return 0
            ;;
    esac
    
    echo ""
    echo -e "  ${BOLD}构建选项:${NC}"
    echo -e "  ${CYAN}1)${NC} 普通构建 (使用缓存)"
    echo -e "  ${CYAN}2)${NC} 完全重建 (无缓存，推荐) ${GREEN}← 推荐${NC}"
    echo ""
    printf "${GREEN}  请选择 [1-2] (默认 2): ${NC}"
    IFS= read -r build_type || build_type="2"
    
    cd "$PROJECT_DIR"
    
    info "停止 PHP 容器..."
    docker compose stop php
    
    info "删除旧的 PHP 镜像..."
    docker compose rm -f php 2>/dev/null || true
    local old_image=$(docker images -q "lnmp-php:*" 2>/dev/null)
    if [[ -n "$old_image" ]]; then
        docker rmi $old_image 2>/dev/null || true
    fi
    
    info "构建新的 PHP 镜像 (版本: $PHP_VERSION)..."
    echo ""
    
    # 注意: set -e 下，构建命令若失败会直接终止脚本，故用 if 直接判定其退出码，
    # 否则下面的失败分支 (error "PHP 镜像构建失败") 永远走不到
    local build_ok=0
    if [[ "$build_type" == "1" ]]; then
        docker compose build php || build_ok=1
    else
        docker compose build --no-cache php || build_ok=1
    fi

    if [[ $build_ok -eq 0 ]]; then
        info "启动 PHP 容器..."
        docker compose up -d php
        
        # 等待容器启动
        sleep 3
        
        # 验证
        if docker compose ps php | grep -q "Up"; then
            log "PHP 镜像构建成功！"
            echo ""
            echo -e "  ${BOLD}新镜像信息:${NC}"
            docker images | grep lnmp-php | head -1
            echo ""
            
            info "已安装的 PHP 扩展:"
            docker compose exec -T php php -m | grep -E "^(mysqli|pdo|curl|zip|mbstring|xml|gd|intl|opcache|redis|bcmath|exif)$" | while read ext; do
                echo -e "    ${GREEN}${ICON_OK}${NC} $ext"
            done
            
            echo ""
            info "PHP 版本信息:"
            docker compose exec -T php php -v | head -1
        else
            error "PHP 容器启动失败，请检查日志: docker compose logs php"
        fi
    else
        error "PHP 镜像构建失败"
    fi
}

cmd_rebuild_mysql() {
    step "${ICON_DATABASE} 重建 MySQL/MariaDB"
    
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        error "请先完成初始安装"
    fi
    source "$PROJECT_DIR/.env"
    
    local current_version=${MARIADB_VERSION:-10.11}
    local current_image=${MARIADB_IMAGE:-mariadb:10.11}
    
    echo ""
    echo -e "  ${BOLD}当前数据库:${NC} ${CYAN}$current_image${NC}"
    echo ""
    echo -e "  ${RED}${ICON_WARN} 警告: 更换数据库版本需要注意数据兼容性！${NC}"
    echo -e "  ${DIM}  - 升级版本通常是安全的${NC}"
    echo -e "  ${DIM}  - 降级版本可能导致数据不兼容${NC}"
    echo -e "  ${DIM}  - 从 MariaDB 切换到 MySQL (或反向) 需要导出/导入数据${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} 使用当前版本重新拉取镜像"
    echo -e "  ${CYAN}2)${NC} 选择新版本"
    echo -e "  ${CYAN}0)${NC} 取消"
    echo ""
    printf "${GREEN}  请选择 [0-2]: ${NC}"
    IFS= read -r rebuild_choice || rebuild_choice=""
    
    case "$rebuild_choice" in
        0)
            info "操作已取消"
            return 0
            ;;
        1)
            # 使用当前版本
            ;;
        2)
            echo ""
            echo -e "  ${BOLD}选择数据库版本:${NC}"
            echo -e "  ${CYAN}1)${NC} MariaDB 10.6  ${DIM}(LTS 长期支持)${NC}"
            echo -e "  ${CYAN}2)${NC} MariaDB 10.11 ${GREEN}← 推荐 (LTS)${NC}"
            echo -e "  ${CYAN}3)${NC} MariaDB 11.0"
            echo -e "  ${CYAN}4)${NC} MariaDB 11.2"
            echo -e "  ${CYAN}5)${NC} MariaDB 11.4  ${DIM}(最新稳定版)${NC}"
            echo -e "  ${CYAN}6)${NC} MySQL 8.0     ${DIM}(使用官方 MySQL)${NC}"
            echo -e "  ${CYAN}7)${NC} 自定义版本"
            echo ""
            printf "${GREEN}  请选择 [1-7]: ${NC}"
            IFS= read -r ver_choice || ver_choice=""
            
            case "$ver_choice" in
                1) MARIADB_VERSION="10.6" ;;
                2) MARIADB_VERSION="10.11" ;;
                3) MARIADB_VERSION="11.0" ;;
                4) MARIADB_VERSION="11.2" ;;
                5) MARIADB_VERSION="11.4" ;;
                6) MARIADB_VERSION="mysql:8.0" ;;
                7)
                    printf "${GREEN}  请输入版本号 (如 10.11 或 mysql:8.0): ${NC}"
                    IFS= read -r custom_ver || custom_ver=""
                    MARIADB_VERSION="${custom_ver:-10.11}"
                    ;;
                *)
                    warn "无效选择，使用当前版本"
                    MARIADB_VERSION="$current_version"
                    ;;
            esac
            
            local new_image=$(get_mariadb_image)
            
            # 更新 .env 文件 (cross-platform sed)
            if [[ "$MARIADB_VERSION" != "$current_version" ]]; then
                if [[ "$(uname)" == "Darwin" ]]; then
                    sed -i '' "s/^MARIADB_VERSION=.*/MARIADB_VERSION=$MARIADB_VERSION/" "$PROJECT_DIR/.env"
                    sed -i '' "s|^MARIADB_IMAGE=.*|MARIADB_IMAGE=$new_image|" "$PROJECT_DIR/.env"
                else
                    sed -i "s/^MARIADB_VERSION=.*/MARIADB_VERSION=$MARIADB_VERSION/" "$PROJECT_DIR/.env"
                    sed -i "s|^MARIADB_IMAGE=.*|MARIADB_IMAGE=$new_image|" "$PROJECT_DIR/.env"
                fi
                log "数据库版本已更新为: $new_image"
                
                # 检查是否在 MariaDB 和 MySQL 之间切换
                if [[ "$current_image" == mysql:* && "$new_image" != mysql:* ]] || \
                   [[ "$current_image" != mysql:* && "$new_image" == mysql:* ]]; then
                    echo ""
                    echo -e "  ${RED}${ICON_WARN} 检测到 MariaDB <-> MySQL 切换！${NC}"
                    echo -e "  ${YELLOW}建议操作:${NC}"
                    echo -e "    1. 先使用 mysqldump 导出当前数据"
                    echo -e "    2. 删除数据目录: rm -rf $PROJECT_DIR/volumes/mysql/data/*"
                    echo -e "    3. 重新启动服务"
                    echo -e "    4. 导入数据到新数据库"
                    echo ""
                    printf "${YELLOW}  是否继续? [y/N]: ${NC}"
                    IFS= read -r switch_confirm || switch_confirm=""
                    if [[ ! "$switch_confirm" =~ ^[Yy]$ ]]; then
                        info "操作已取消"
                        return 0
                    fi
                fi
            fi
            ;;
        *)
            info "操作已取消"
            return 0
            ;;
    esac
    
    cd "$PROJECT_DIR"
    
    info "停止 MySQL 容器..."
    docker compose stop mysql
    
    info "删除旧容器..."
    docker compose rm -f mysql 2>/dev/null || true
    
    local new_image=$(get_mariadb_image)
    info "拉取新镜像: $new_image..."
    docker pull "$new_image"
    
    info "启动 MySQL 容器..."
    docker compose up -d mysql
    
    # 等待数据库启动 (compatible with both MariaDB and MySQL)
    info "等待数据库启动..."
    local max_wait=90
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        # Try both mysqladmin and mariadb-admin
        if docker compose exec -T mysql mysqladmin ping -h localhost 2>/dev/null || \
           docker compose exec -T mysql mariadb-admin ping -h localhost 2>/dev/null; then
            break
        fi
        sleep 3
        waited=$((waited + 3))
        printf "."
    done
    echo ""
    
    if docker compose ps mysql | grep -q "Up"; then
        log "MySQL/MariaDB 重建完成！"
        echo ""
        echo -e "  ${BOLD}数据库信息:${NC}"
        docker compose exec -T mysql mysql --version 2>/dev/null || echo "  (无法获取版本信息)"
    else
        warn "MySQL 容器可能未正常启动，请检查日志: docker compose logs mysql"
    fi
}

# 重置 MySQL/MariaDB root 密码 (使用 skip-grant-tables, 不影响数据)
cmd_reset_mysql_password() {
    step "${ICON_LOCK} 重置 MySQL/MariaDB root 密码"

    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        error "未找到 .env，请先完成初始安装"
    fi
    source "$PROJECT_DIR/.env"
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"

    local reset_container="${PROJECT_NAME}_mysql_reset"

    echo ""
    echo -e "  ${DIM}数据保存在持久化卷中，此操作仅重置 root 密码，${NC}${BOLD}不会影响数据库数据${NC}${DIM}。${NC}"

    # 1) 先检测当前记录的密码是否其实可用 (可能只是应用端配错了)
    if [[ -n "${MYSQL_ROOT_PASS:-}" ]] && docker compose ps mysql 2>/dev/null | grep -q "Up"; then
        if MYSQL_PWD="$MYSQL_ROOT_PASS" docker compose exec -T -e MYSQL_PWD mysql sh -c "mariadb -uroot -e 'SELECT 1' 2>/dev/null || mysql -uroot -e 'SELECT 1' 2>/dev/null" >/dev/null 2>&1; then
            echo ""
            warn ".env 中记录的 root 密码其实是可用的！"
            echo -e "  ${DIM}很可能是你的应用/连接工具里的密码写错了，而不是数据库密码丢失。${NC}"
            echo -e "  ${DIM}当前有效密码见: $CREDENTIALS_FILE${NC}"
            echo ""
            printf "${YELLOW}  仍要强制重置为新密码吗? [y/N]: ${NC}"
            IFS= read -r force_confirm || force_confirm=""
            [[ "$force_confirm" =~ ^[Yy]$ ]] || { info "操作已取消"; return 0; }
        fi
    fi

    # 2) 确定新密码
    local new_pass=""
    echo ""
    echo -e "  ${CYAN}1)${NC} 自动生成强密码 ${GREEN}(推荐)${NC}"
    echo -e "  ${CYAN}2)${NC} 手动输入新密码"
    echo -e "  ${CYAN}0)${NC} 取消"
    echo ""
    printf "${GREEN}  请选择 [0-2]: ${NC}"
    IFS= read -r pass_choice || pass_choice=""
    case "$pass_choice" in
        1|"") new_pass=$(generate_strong_password) ;;
        2)
            printf "${GREEN}  请输入新密码 (建议仅字母和数字, >=12 位): ${NC}"
            IFS= read -r new_pass || new_pass=""
            [[ -n "$new_pass" ]] || error "密码不能为空"
            if [[ "$new_pass" =~ [^a-zA-Z0-9] ]]; then
                warn "检测到特殊字符，为避免转义问题，建议仅使用字母和数字"
                printf "${YELLOW}  仍要继续? [y/N]: ${NC}"
                IFS= read -r sp_confirm || sp_confirm=""
                [[ "$sp_confirm" =~ ^[Yy]$ ]] || { info "操作已取消"; return 0; }
            fi
            ;;
        *) info "操作已取消"; return 0 ;;
    esac

    # 3) 停止正常容器，清理可能残留的临时容器
    info "停止 MySQL 容器..."
    docker compose stop mysql
    docker rm -f "$reset_container" 2>/dev/null || true

    # 4) 以 skip-grant-tables 模式启动临时容器 (复用同一数据卷)
    info "以 skip-grant-tables 模式启动临时容器..."
    # 临时容器启动失败时，正常 mysql 已被 stop，需恢复启动后再报错，避免服务停摆
    if ! docker compose run --no-deps -d --name "$reset_container" mysql \
        --skip-grant-tables --skip-networking >/dev/null; then
        docker rm -f "$reset_container" 2>/dev/null || true
        docker compose up -d mysql
        error "临时容器启动失败，已恢复正常 MySQL 容器，请查看日志: docker compose logs mysql"
    fi

    # 5) 等待临时数据库就绪
    info "等待临时数据库就绪..."
    local waited=0
    while [[ $waited -lt 60 ]]; do
        if docker exec "$reset_container" sh -c "mariadb-admin ping 2>/dev/null || mysqladmin ping 2>/dev/null" >/dev/null 2>&1; then
            break
        fi
        sleep 2; waited=$((waited + 2)); printf "."
    done
    echo ""

    # 6) 探测客户端并重置密码 (兼容 MariaDB / MySQL)
    local cli
    cli=$(docker exec "$reset_container" sh -c "command -v mariadb || command -v mysql" 2>/dev/null | head -1) || true
    [[ -n "$cli" ]] || cli="mariadb"

    info "重置 root 密码..."
    if ! printf "%s\n" \
        "FLUSH PRIVILEGES;" \
        "ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_pass}';" \
        "FLUSH PRIVILEGES;" \
        | docker exec -i "$reset_container" "$cli" -uroot; then
        docker rm -f "$reset_container" 2>/dev/null || true
        docker compose up -d mysql
        error "重置失败，已尝试恢复正常容器，请查看日志: docker compose logs mysql"
    fi
    # root@'%' 账户可能不存在，忽略错误
    printf "%s\n" \
        "ALTER USER 'root'@'%' IDENTIFIED BY '${new_pass}';" \
        "FLUSH PRIVILEGES;" \
        | docker exec -i "$reset_container" "$cli" -uroot 2>/dev/null || true

    # 7) 关闭临时容器
    info "关闭临时容器..."
    docker rm -f "$reset_container" 2>/dev/null || true

    # 8) 同步新密码到 .env 和 .credentials
    info "更新配置文件中的密码..."
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|^MYSQL_ROOT_PASS=.*|MYSQL_ROOT_PASS=$new_pass|" "$PROJECT_DIR/.env"
        [[ -f "$CREDENTIALS_FILE" ]] && sed -i '' "s|^MySQL Root 密码:.*|MySQL Root 密码: $new_pass|" "$CREDENTIALS_FILE"
    else
        sed -i "s|^MYSQL_ROOT_PASS=.*|MYSQL_ROOT_PASS=$new_pass|" "$PROJECT_DIR/.env"
        [[ -f "$CREDENTIALS_FILE" ]] && sed -i "s|^MySQL Root 密码:.*|MySQL Root 密码: $new_pass|" "$CREDENTIALS_FILE"
    fi

    # 9) 正常启动并验证
    info "启动 MySQL 容器..."
    docker compose up -d mysql
    info "等待数据库启动..."
    waited=0
    while [[ $waited -lt 90 ]]; do
        if docker compose exec -T mysql sh -c "mariadb-admin ping -h localhost 2>/dev/null || mysqladmin ping -h localhost 2>/dev/null" >/dev/null 2>&1; then
            break
        fi
        sleep 3; waited=$((waited + 3)); printf "."
    done
    echo ""

    if MYSQL_PWD="$new_pass" docker compose exec -T -e MYSQL_PWD mysql sh -c "mariadb -uroot -e 'SELECT 1' 2>/dev/null || mysql -uroot -e 'SELECT 1' 2>/dev/null" >/dev/null 2>&1; then
        log "root 密码重置成功！(已验证 root@localhost)"
        echo ""
        echo -e "  ${BOLD}新的 root 密码:${NC} ${GREEN}$new_pass${NC}"
        echo -e "  ${DIM}已同步到: $PROJECT_DIR/.env 和 $CREDENTIALS_FILE${NC}"
        echo ""
        echo -e "  ${DIM}注: 已尽力重置 root@'%' (供容器网络内远程连接)，但该账户仅在存在时才生效、且未做网络验证。${NC}"
        echo -e "  ${DIM}    若应用 (如 PHP 容器) 以 root 跨网络连接仍失败，请检查 root@'%' 账户是否存在。${NC}"
        echo ""
        echo -e "  ${YELLOW}${ICON_WARN} 请记得同步更新你的应用程序数据库连接密码！${NC}"
    else
        warn "新密码验证失败，请检查日志: docker compose logs mysql"
    fi
}

cmd_uninstall() {
    [[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行"
    step "${ICON_WARN} 卸载确认"

    # 先校验要删除的目录，任何文件都还没动: 必须是本脚本部署的目录，且不能是系统目录
    local uninstall_dir; uninstall_dir=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || true
    [[ -n "$uninstall_dir" ]] || error "项目目录不存在: $PROJECT_DIR"
    case "$uninstall_dir" in
        /|/root|/home|/etc|/usr|/var|/opt|/srv|/tmp|/boot|/bin|/sbin|/lib|/lib64|/data)
            error "拒绝删除系统目录 '$uninstall_dir'，请手动清理" ;;
    esac
    [[ "$uninstall_dir" == /home/* && "$uninstall_dir" != /home/*/* ]] && error "拒绝删除用户主目录 '$uninstall_dir'"
    is_lnmp_project_dir "$uninstall_dir" || error "拒绝删除 '$uninstall_dir': 未找到本脚本生成的 .env 与 docker-compose.yml"

    echo ""
    echo -e "  ${BOLD}将删除目录:${NC} ${CYAN}${uninstall_dir}${NC}"
    echo -e "  ${RED}警告: 此操作将删除所有数据，包括:${NC}"
    echo -e "    - Docker 容器和镜像"
    echo -e "    - 数据库数据"
    echo -e "    - 网站文件"
    echo -e "    - SSL 证书"
    echo -e "    - 配置文件"
    echo ""
    printf "${RED}  确定要继续吗? 输入 'yes' 确认: ${NC}"
    IFS= read -r confirm || confirm=""
    
    if [[ "$confirm" != "yes" ]]; then
        info "操作已取消"
        exit 0
    fi
    
    step "${ICON_WARN} 正在卸载..."
    
    cd "$PROJECT_DIR" 2>/dev/null && {
        docker compose down -v --rmi all 2>/dev/null || true
    }
    
    # 删除 crontab 任务 (only remove lines from this project: backup / renew / log rotate)
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "$PROJECT_DIR/backup_task.sh" | grep -v "$PROJECT_DIR/renew-cert.sh" \
        | grep -v "$PROJECT_DIR/log_rotate.sh" | grep -v "$PROJECT_DIR/geoip_update.sh" \
        | grep -v "$PROJECT_DIR/f2b_bridge.sh" > "$temp_cron" 2>/dev/null || true
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"

    # 清理 fail2ban 配置: 项目目录删除后 jail 的 logpath 不存在，会让整个 fail2ban
    # 启动失败 (连 sshd 防护也一起失效)。只删本项目生成的文件，系统自带配置不动。
    rm -f /etc/fail2ban/jail.d/lnmp.local /etc/fail2ban/filter.d/lnmp-nginx.conf \
          /etc/fail2ban/action.d/docker-user.conf
    iptables  -D DOCKER-USER -m set --match-set f2b-lnmp  src -j DROP 2>/dev/null || true
    ip6tables -D DOCKER-USER -m set --match-set f2b-lnmp6 src -j DROP 2>/dev/null || true
    ipset destroy f2b-lnmp  2>/dev/null || true
    ipset destroy f2b-lnmp6 2>/dev/null || true
    if command -v fail2ban-client &>/dev/null; then
        systemctl restart fail2ban 2>/dev/null || true
    fi

    # 凭据和数据库备份要放到项目目录「外面」: 脚本从 lnmp/deploy.sh 运行时 SCRIPT_DIR 就是项目目录，
    # 放在那里会被下面的 rm -rf 一起删掉
    local keep_dir; keep_dir="$(dirname "$uninstall_dir")"
    # 凭据含明文密码，须保持 600；install -m600 原子创建，避免 cp 默认 644
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        local cred_backup="$keep_dir/lnmp_credentials_backup_$(date +%Y%m%d_%H%M%S).txt"
        install -m 600 "$CREDENTIALS_FILE" "$cred_backup" 2>/dev/null \
            || { cp "$CREDENTIALS_FILE" "$cred_backup"; chmod 600 "$cred_backup"; }
        info "凭据已备份到 $cred_backup"
    fi
    # 数据库备份 (backups/) 移出项目目录保留
    if [[ -d "$uninstall_dir/backups" ]] && [[ -n "$(ls -A "$uninstall_dir/backups" 2>/dev/null)" ]]; then
        local db_keep="$keep_dir/lnmp_backups_$(date +%Y%m%d_%H%M%S)"
        mv "$uninstall_dir/backups" "$db_keep" && chmod 700 "$db_keep" \
            && info "数据库备份已移到 $db_keep"
    fi
    
    # 云盘备份是异地副本，卸载不主动删除 (删了反而危险)。提示用户如何手动清理。
    local cloud_remote="" cloud_img="" cloud_cfg="" cloud_conf=""
    if [[ -f "$uninstall_dir/.rclone-backup.env" ]]; then
        cloud_remote=$(grep -m1 '^RCLONE_REMOTE='      "$uninstall_dir/.rclone-backup.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
        cloud_img=$(   grep -m1 '^RCLONE_IMAGE='       "$uninstall_dir/.rclone-backup.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
        cloud_cfg=$(   grep -m1 '^RCLONE_CONFIG_DIR='  "$uninstall_dir/.rclone-backup.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
        cloud_conf=$(  grep -m1 '^RCLONE_CONFIG_FILE=' "$uninstall_dir/.rclone-backup.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
    fi

    # 删除目录 (路径已在开头校验过)
    rm -rf "$uninstall_dir"

    log "卸载完成"
    if [[ -n "$cloud_remote" ]]; then
        echo ""
        warn "云盘备份未删除 (异地副本需你自行决定)。如需清理，运行:"
        echo -e "    ${CYAN}docker run --rm -v ${cloud_cfg:-<配置目录>}:/config:ro ${cloud_img:-rclone/rclone} --config ${cloud_conf:-/config/rclone.conf} delete ${cloud_remote}/${NC}"
    fi
}

cmd_cert_only() {
    show_banner
    step "${ICON_LOCK} 重新申请 SSL 证书"
    
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        # 首次申请，需要收集信息
        collect_domain_info
    else
        source "$PROJECT_DIR/.env"
        source "$PROGRESS_FILE" 2>/dev/null || true
        # .env 里 SUBDOMAINS 以 SUBDOMAINS_LIST 标量保存，还原为数组；
        # 仅当 SUBDOMAINS_LIST 非空时才覆盖，否则沿用进度文件恢复的 SUBDOMAINS，
        # 避免 .env 缺该值时清空已有子域名导致重签证书丢子域名
        if [[ -n "${SUBDOMAINS_LIST:-}" ]]; then
            SUBDOMAINS=(${SUBDOMAINS_LIST})
        fi
    fi

    # 总是询问证书类型（用户可能想更改类型）
    select_cert_type
    
    obtain_ssl_certificate || exit 1
    setup_nginx_final
    
    # 保存证书类型到 .env
    if [[ -f "$PROJECT_DIR/.env" ]] && ! grep -q "^CERT_TYPE=" "$PROJECT_DIR/.env"; then
        echo "CERT_TYPE=$CERT_TYPE" >> "$PROJECT_DIR/.env"
    fi
    if [[ -n "$DNS_PROVIDER" ]] && ! grep -q "^DNS_PROVIDER=" "$PROJECT_DIR/.env"; then
        echo "DNS_PROVIDER=$DNS_PROVIDER" >> "$PROJECT_DIR/.env"
    fi
    
    cd "$PROJECT_DIR"
    docker compose restart nginx
    log "证书申请完成，Nginx 已重载"
}

cmd_upgrade() {
    step "${ICON_GEAR} 检查脚本更新"
    
    info "当前版本: v${VERSION}"
    
    # 检查是否有网络连接
    if ! curl -s --connect-timeout 5 https://raw.githubusercontent.com &>/dev/null; then
        warn "无法连接到更新服务器，请检查网络连接"
        return 1
    fi
    
    # 获取远程版本信息
    # 临时文件优先建在脚本同目录，使后续 mv 成为同文件系统的原子 rename，
    # 避免跨文件系统 mv 覆盖正在运行脚本的 inode 导致读到半成品
    local remote_version=""
    local temp_script
    temp_script=$(mktemp "${SCRIPT_DIR}/.deploy-upgrade.XXXXXX" 2>/dev/null || mktemp)
    
    info "检查最新版本..."
    if curl -fsSL --connect-timeout 10 "$SCRIPT_URL" -o "$temp_script" 2>/dev/null; then
        remote_version=$(grep -m1 '^VERSION=' "$temp_script" | cut -d'"' -f2) || true
        
        if [[ -z "$remote_version" ]]; then
            warn "无法获取远程版本信息"
            rm -f "$temp_script"
            return 1
        fi
        
        echo -e "  ${BOLD}当前版本:${NC} v${VERSION}"
        echo -e "  ${BOLD}最新版本:${NC} v${remote_version}"
        echo ""
        
        # 比较版本号 (semantic version comparison)
        version_compare() {
            # Returns: 0 if equal, 1 if $1 > $2, 2 if $1 < $2
            if [[ "$1" == "$2" ]]; then return 0; fi
            local IFS=.
            local i ver1=($1) ver2=($2)
            # Fill empty fields with zeros
            for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
            for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do ver2[i]=0; done
            for ((i=0; i<${#ver1[@]}; i++)); do
                if [[ -z "${ver2[i]}" ]]; then ver2[i]=0; fi
                if ((10#${ver1[i]} > 10#${ver2[i]})); then return 1; fi
                if ((10#${ver1[i]} < 10#${ver2[i]})); then return 2; fi
            done
            return 0
        }
        
        # 注意: version_compare 相等返回 0、否则返回 1/2。在 set -e 下裸调用非零会直接退出，
        # 必须用 || true 兜住，否则"发现新版本"的升级分支永远走不到。
        local cmp_result=0
        version_compare "$VERSION" "$remote_version" || cmp_result=$?
        
        if [[ $cmp_result -eq 0 ]]; then
            log "您已经在使用最新版本"
            rm -f "$temp_script"
            return 0
        fi
        
        # Check if current version is older than remote
        if [[ $cmp_result -eq 2 ]]; then
            echo -e "  ${GREEN}发现新版本！${NC}"
            echo ""
            printf "${GREEN}  是否升级到 v${remote_version}? [y/N]: ${NC}"
            IFS= read -r upgrade_confirm || upgrade_confirm=""
            
            if [[ "$upgrade_confirm" =~ ^[Yy]$ ]]; then
                # 备份当前脚本
                local backup_file="$0.backup.$(date +%Y%m%d_%H%M%S)"
                cp "$0" "$backup_file"
                info "当前脚本已备份到: $backup_file"
                
                # 替换脚本
                if mv "$temp_script" "$0" && chmod +x "$0"; then
                    log "脚本已升级到 v${remote_version}"
                    info "如果遇到问题，可以从备份恢复: $backup_file"
                    echo ""
                    echo -e "  ${YELLOW}请重新运行脚本以使用新版本${NC}"
                else
                    error "升级失败，请检查权限"
                fi
            else
                info "升级已取消"
                rm -f "$temp_script"
            fi
        else
            log "您的版本比远程版本更新 (可能是开发版本)"
            rm -f "$temp_script"
        fi
    else
        warn "无法下载更新，请检查网络连接或 URL 是否正确"
        rm -f "$temp_script"
        return 1
    fi
}

cmd_cleanup() {
    step "${ICON_GEAR} 清理 Docker 资源"
    
    echo ""
    echo -e "  ${BOLD}即将清理以下内容:${NC}"
    echo -e "    - 停止的容器"
    echo -e "    - 未使用的网络"
    echo -e "    - 悬空的镜像 (dangling images)"
    echo -e "    - 构建缓存"
    echo ""
    printf "${YELLOW}  是否继续? [y/N]: ${NC}"
    IFS= read -r cleanup_confirm || cleanup_confirm=""
    
    if [[ ! "$cleanup_confirm" =~ ^[Yy]$ ]]; then
        info "操作已取消"
        return 0
    fi
    
    echo ""
    info "清理停止的容器..."
    docker container prune -f 2>/dev/null || true
    
    info "清理未使用的网络..."
    docker network prune -f 2>/dev/null || true
    
    info "清理悬空的镜像..."
    docker image prune -f 2>/dev/null || true
    
    info "清理构建缓存..."
    docker builder prune -f 2>/dev/null || true
    
    echo ""
    log "Docker 资源清理完成"
    
    # 显示清理后的空间使用情况
    echo ""
    echo -e "  ${BOLD}当前 Docker 磁盘使用:${NC}"
    docker system df 2>/dev/null || true
}

cmd_renew() {
    step "${ICON_LOCK} 续期 SSL 证书"
    cd "$PROJECT_DIR" 2>/dev/null || error "项目目录不存在"
    
    info "检查证书续期状态..."
    # 与 renew-cert.sh 一致: 用带 Cloudflare 插件的镜像，通配符证书才能续上
    if docker run --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" -v "$PROJECT_DIR/certbot/www:/var/www/certbot" \
            certbot/dns-cloudflare renew; then
        info "测试 Nginx 配置..."
        if docker compose exec -T nginx nginx -t 2>/dev/null; then
            docker compose exec -T nginx nginx -s reload
            log "证书续期检查完成，Nginx 已重载"
        else
            warn "Nginx 配置测试失败，请检查配置文件"
        fi
    else
        warn "证书续期失败，请检查日志"
    fi
}

# 从现有 .env 一键重新生成所有配置并重建，把时区/内存/证书续期/备份等
# 给已有站点 .conf 补上 HTTP/3 (QUIC)。幂等: 已含 quic 的文件跳过。
# reuseport 全局只能一处，只给主域名 01-<域名>.conf；其余用不带 reuseport 的 listen。
# 直接改盘上文件，调用方负责随后 nginx -t + 回滚。
migrate_site_confs_http3() {
    local nginx_conf_dir main_base
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/config/nginx/site-confs"
    else
        nginx_conf_dir="$PROJECT_DIR/volumes/nginx/conf.d"
    fi
    [[ -d "$nginx_conf_dir" ]] || return 0
    main_base="01-${DOMAIN}.conf"

    local f base reuse changed=0
    for f in "$nginx_conf_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        grep -q 'quic' "$f" 2>/dev/null && continue          # 已迁移，跳过
        grep -qE 'listen[[:space:]]+443[[:space:]]+ssl' "$f" 2>/dev/null || continue
        base="$(basename "$f")"
        reuse=""; [[ "$base" == "$main_base" ]] && reuse=" reuseport"
        # 在 "listen 443 ssl;" 后插入 quic listen；"http2 on;" 后插入 "http3 on;"；
        # server_name 后插入 Alt-Svc (放在 server 块内、紧跟 server_name，一定在 http{} 之外的合法位置)
        awk -v reuse="$reuse" '
            { print }
            /listen[[:space:]]+443[[:space:]]+ssl/ && !q { print "    listen 443 quic" reuse ";"; q=1 }
            /http2[[:space:]]+on;/ && !h3 { print "    http3 on;"; h3=1 }
            /server_name/ && !alt { print "    add_header Alt-Svc '\''h3=\":443\"; ma=86400'\'' always;"; alt=1 }
        ' "$f" > "$f.h3tmp" && mv "$f.h3tmp" "$f" && changed=$((changed+1))
    done
    [[ $changed -gt 0 ]] && info "已为 $changed 个站点配置启用 HTTP/3"
    return 0
}

# 修复应用到已运行的部署。数据库数据、SSL 证书、子域名配置、网站文件均不改动。
cmd_reconfig() {
    show_banner
    step "${ICON_GEAR} 重新生成配置并应用到现有部署"

    # 载入现有配置 (含旧版 .env 缺键时的 NGINX_TYPE / phpMyAdmin 探测与子域名还原)
    load_existing_env

    # 重新按当前机器内存/CPU 定档，避免以默认档位生成 PHP/MySQL 参数
    detect_server_config

    # ---- 展示将执行的操作并确认 ----
    echo ""
    echo -e "  ${BOLD}将重新生成的配置:${NC}"
    echo -e "    ${DIM}- PHP Dockerfile / www.conf / custom.ini${NC}"
    echo -e "    ${DIM}- MySQL custom.cnf${NC}"
    echo -e "    ${DIM}- docker-compose.yml + .env${NC}"
    echo -e "    ${DIM}- Nginx 主配置 (nginx.conf)${NC}"
    echo -e "    ${DIM}- backup_task.sh / renew-cert.sh${NC}"
    echo ""
    echo -e "  ${BOLD}检测到的部署拓扑:${NC}"
    echo -e "    ${DIM}├─ 服务器档位:${NC} ${CYAN}${SERVER_TIER} (${SERVER_MEM_MB}MB / ${SERVER_CPU_CORES} 核)${NC}"
    echo -e "    ${DIM}├─ Nginx 类型:${NC} ${CYAN}${NGINX_TYPE}${NC}"
    echo -e "    ${DIM}├─ phpMyAdmin:${NC} ${CYAN}${INSTALL_PHPMYADMIN}${NC}"
    echo -e "    ${DIM}├─ PHP 版本:${NC}   ${CYAN}${PHP_VERSION}${NC}"
    echo -e "    ${DIM}└─ 域名:${NC}       ${CYAN}${DOMAIN}${NC}"
    echo ""
    echo -e "  ${GREEN}将保留不动:${NC} 数据库数据 / SSL 证书 / 子域名与站点配置 / 网站文件"
    if [[ "$NGINX_TYPE" == "official" ]]; then
        echo -e "  ${YELLOW}将重建 PHP 与官方 Nginx 镜像 (应用时区)，首次可能耗时几分钟${NC}"
    else
        echo -e "  ${YELLOW}将重建 PHP 镜像 (应用时区)，首次可能耗时几分钟${NC}"
    fi
    echo ""
    printf "${GREEN}  确认继续? [y/N]: ${NC}"
    IFS= read -r confirm || confirm=""
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "操作已取消"
        return 0
    fi

    # 改任何 nginx 配置前整体打包备份 (含站点 .conf 与 compose)，HTTP/3 迁移或重写后
    # nginx -t 不通过时可整体还原，避免坏配置留在盘上导致下次重启起不来
    local reconf_backup
    reconf_backup="$(mktemp /tmp/lnmp-reconfig-backup.XXXXXX.tar)"
    local reconf_paths=(docker-compose.yml)
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        [[ -d "$PROJECT_DIR/volumes/nginx/config/nginx" ]] && reconf_paths+=(volumes/nginx/config/nginx)
    else
        local rp
        for rp in volumes/nginx/nginx.conf volumes/nginx/waf-guard.conf volumes/nginx/conf.d; do
            [[ -e "$PROJECT_DIR/$rp" ]] && reconf_paths+=("$rp")
        done
    fi
    tar -C "$PROJECT_DIR" -cf "$reconf_backup" "${reconf_paths[@]}" 2>/dev/null \
        && info "已备份当前配置: $reconf_backup" || reconf_backup=""

    # ---- 重新生成配置文件 (复用安装期函数，全局变量已就位) ----
    setup_php_dockerfile
    setup_php_ini_config
    setup_mysql_config
    [[ "$NGINX_TYPE" == "official" ]] && setup_nginx_dockerfile
    setup_nginx_main_config          # 仅重写主 nginx.conf，不触碰站点/子域名配置
    setup_nginx_initial              # 重写 00-http-redirect.conf (补 /healthz 健康检查端点)，不触碰站点/子域名配置
    setup_waf_guard                  # 重写 WAF 守卫片段
    inject_waf_include               # 幂等为已有站点注入 WAF include
    migrate_site_confs_http3         # 幂等为已有站点 .conf 启用 HTTP/3 (QUIC)
    setup_docker_compose             # 重写 docker-compose.yml + .env (完成迁移值回写，含 UDP 443 端口)
    setup_backup                     # 重写 backup_task.sh (D 修复)，crontab 幂等
    setup_cert_renewal               # 重写 renew-cert.sh (A 修复)，crontab 幂等
    setup_log_rotate                 # 日志超 10M 自动截断，crontab 幂等
    # fail2ban: 已装则刷新配置 (jail 日志路径随 NGINX_TYPE)；桥接任务幂等
    if command -v fail2ban-client &>/dev/null; then
        install_fail2ban            # 补装 ipset (封禁动作依赖它)，已装则跳过
        setup_fail2ban_config
        setup_f2b_bridge
    fi

    # ---- 重建镜像并重启 ----
    step "${ICON_ROCKET} 重建镜像并重启服务"
    cd "$PROJECT_DIR" || error "无法进入项目目录"

    info "重建 PHP 镜像 (应用时区/内存配置)..."
    docker compose build php

    if [[ "$NGINX_TYPE" == "official" ]]; then
        info "重建 Nginx 镜像 (应用时区)..."
        docker compose build nginx
    fi

    info "重建容器 (应用时区环境变量、时区挂载、redis 内存上限等、UDP 443)..."
    docker compose up -d
    sleep 2

    # 校验新配置 (含 HTTP/3)。不通过则从备份整体还原并重启，避免坏配置留在盘上
    if ! docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        warn "nginx 配置检查未通过，错误如下:"
        docker compose exec -T nginx nginx -t 2>&1 | tail -8 || true
        if [[ -n "$reconf_backup" && -f "$reconf_backup" ]]; then
            warn "正在从备份还原配置..."
            tar -C "$PROJECT_DIR" -xf "$reconf_backup" \
                && docker compose up -d >/dev/null 2>&1 \
                && docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 || true
            error "已还原到重配前的配置 (备份: $reconf_backup)"
        fi
        error "nginx 配置检查失败，请检查上面的错误"
    fi

    info "重载 Nginx 配置..."
    docker compose exec -T nginx nginx -s reload 2>/dev/null || docker compose restart nginx
    [[ -n "$reconf_backup" && -f "$reconf_backup" ]] && rm -f "$reconf_backup"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ${ICON_OK} ${BOLD}重新配置完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}${ICON_OK}${NC} 数据库数据 / SSL 证书 / 子域名配置 / 网站文件均未改动"
    echo -e "  ${GREEN}${ICON_OK}${NC} 时区、内存、证书续期、备份保留天数等修复已应用"
    echo ""
    echo -e "  ${DIM}提示: redis / standard-nginx / certbot 跟随宿主机时区，${NC}"
    echo -e "  ${DIM}      建议宿主机执行: timedatectl set-timezone Asia/Shanghai${NC}"
    echo ""
    echo -e "  ${DIM}可运行 $0 --health 检查各服务状态${NC}"
    echo ""
}

# ======================== 主安装流程 ========================
run_full_install() {
    show_banner

    # 已部署 (有 .env 且没有未完成的进度) 时禁止直接重装: 会生成新的数据库密码 (而已有数据目录
    # 仍是旧密码，应用与备份全部连不上)，并覆盖站点配置和网站首页。
    if [[ -f "$PROJECT_DIR/.env" && ! -f "$PROGRESS_FILE" ]]; then
        echo ""
        warn "检测到已有部署: $PROJECT_DIR"
        echo -e "  ${DIM}重新安装会生成新的数据库密码 (已有数据库仍是旧密码，网站会连不上)，${NC}"
        echo -e "  ${DIM}并覆盖站点配置与网站首页文件。${NC}"
        echo -e "  ${DIM}只想更新配置、保留数据，请改用: $0 --reconfig${NC}"
        echo ""
        printf "${RED}  确定要覆盖重装吗? 输入 'yes' 继续: ${NC}"
        local overwrite; IFS= read -r overwrite || overwrite=""
        [[ "$overwrite" == "yes" ]] || { info "已取消"; exit 0; }
    fi

    # 检查是否可以恢复。菜单传入的 INSTALL_FAIL2BAN 以本次选择为准，不被旧进度文件里的值覆盖
    local menu_f2b="${INSTALL_FAIL2BAN:-}"
    if load_progress; then
        [[ -n "$menu_f2b" ]] && INSTALL_FAIL2BAN="$menu_f2b"
        echo ""
        info "检测到未完成的安装 (阶段: $STAGE)"
        printf "${GREEN}  是否继续上次安装? [Y/n]: ${NC}"
        IFS= read -r resume || resume=""
        if [[ ! "$resume" =~ ^[Nn]$ ]]; then
            info "恢复安装..."
        else
            clear_progress
            STAGE=""
            # 选择不恢复时，重置从进度文件读入的变量，确保真正从头开始
            # (否则 DOMAIN 等仍有值，会跳过重新询问而沿用旧配置)
            DOMAIN=""
            SUBDOMAINS=()
            CERT_TYPE="single"
            DNS_PROVIDER=""
            INSTALL_PHPMYADMIN="no"
            NGINX_TYPE="official"
            MYSQL_ROOT_PASS=""
            REDIS_PASSWORD=""
            INSTALL_FAIL2BAN="${menu_f2b:-yes}"
        fi
    fi

    # 无条件检测服务器配置: 续装时进度文件不保存档位，必须每次重新检测，
    # 否则会以默认 medium/1024MB 生成 PHP/MySQL/Nginx 配置 (档位算错)
    detect_server_config

    local stages=("env" "docker" "config" "dirs" "compose" "nginx_init" "cert" "nginx_final" "services" "backup" "done")
    local current_stage=${STAGE:-env}
    local stage_index=0
    
    for i in "${!stages[@]}"; do
        [[ "${stages[$i]}" == "$current_stage" ]] && stage_index=$i && break
    done
    
    # Stage: env
    if [[ $stage_index -le 0 ]]; then
        check_env
        save_progress "docker"
    fi
    
    # Stage: docker
    if [[ $stage_index -le 1 ]]; then
        install_docker
        save_progress "config"
    fi
    
    # Stage: config
    if [[ $stage_index -le 2 ]]; then
        if [[ -z "$DOMAIN" ]]; then
            collect_domain_info
        fi
        select_nginx_type
        if [[ -z "$CERT_TYPE" || "$CERT_TYPE" == "single" ]]; then
            select_cert_type
        fi
        select_php_version
        select_mariadb_version
        ask_phpmyadmin
        collect_credentials
        check_dns "$DOMAIN"
        save_progress "dirs"
    fi
    
    # Stage: dirs
    if [[ $stage_index -le 3 ]]; then
        setup_directories
        save_progress "compose"
    fi
    
    # Stage: compose
    if [[ $stage_index -le 4 ]]; then
        setup_php_dockerfile
        setup_php_ini_config
        setup_mysql_config
        # Build nginx dockerfile for official nginx with GeoIP2
        if [[ "$NGINX_TYPE" == "official" ]]; then
            setup_nginx_dockerfile
        fi
        setup_nginx_main_config
        setup_waf_guard          # WAF 守卫片段 (compose 会挂载它，须在 up 之前生成)
        setup_docker_compose
        save_progress "nginx_init"
    fi

    # Stage: nginx_init
    if [[ $stage_index -le 5 ]]; then
        setup_nginx_initial
        save_progress "cert"
    fi
    
    # Stage: cert
    if [[ $stage_index -le 6 ]]; then
        if ! obtain_ssl_certificate; then
            save_progress "cert"
            exit 1
        fi
        save_progress "nginx_final"
    fi
    
    # Stage: nginx_final
    if [[ $stage_index -le 7 ]]; then
        setup_nginx_final
        setup_index_page
        # WAF 守卫 include 已由 setup_nginx_final 写入各站点模板；WAF (拦 bad bot +
        # 限流) 是纯 nginx 配置、始终启用。fail2ban + 网页解封面板为可选项，
        # 由 INSTALL_FAIL2BAN 控制 (主菜单选 1 只装 LNMP 时为 no)。
        if [[ "${INSTALL_FAIL2BAN:-yes}" == "yes" ]]; then
            install_fail2ban
            setup_fail2ban_config
            setup_f2b_panel
            setup_f2b_bridge
        else
            info "已跳过 fail2ban 安装 (WAF 拦截与限流仍生效)；如需启用可随时运行: $0 --setup-waf"
        fi
        save_progress "services"
    fi
    
    # Stage: services
    if [[ $stage_index -le 8 ]]; then
        step "${ICON_ROCKET} 构建和启动服务"
        cd "$PROJECT_DIR"
        
        info "构建 PHP 镜像 (首次可能需要几分钟)..."
        docker compose build php &
        spinner $! "构建 PHP 镜像中..."
        wait
        
        info "启动所有服务..."
        # --build 确保官方 Nginx 的本地镜像 (lnmp-nginx-geoip2) 被构建，
        # 通配符证书场景下 Nginx 首次启动在此，需在此构建
        docker compose up -d --build

        info "等待服务启动..."
        sleep 5
        
        # 检查 PHP 容器是否运行
        if docker compose ps php | grep -q "Up"; then
            log "PHP 容器运行正常 (所有扩展已预装)"
            
            # 显示已安装的扩展
            info "已安装的 PHP 扩展:"
            docker compose exec -T php php -m | grep -E "^(mysqli|pdo|curl|zip|mbstring|xml|gd|intl|opcache|redis|bcmath|exif)$" | while read ext; do
                echo -e "    ${GREEN}${ICON_OK}${NC} $ext"
            done
        else
            warn "PHP 容器可能未正常启动，请检查: docker compose logs php"
        fi
        
        # 重新加载 Nginx 确保配置生效
        info "重新加载 Nginx 配置..."
        docker compose exec -T nginx nginx -s reload 2>/dev/null || docker compose restart nginx
        
        # 验证网站文件
        info "验证网站文件..."
        if [[ -f "$PROJECT_DIR/volumes/php/www/$DOMAIN/index.php" ]]; then
            log "网站文件已就绪: $PROJECT_DIR/volumes/php/www/$DOMAIN/index.php"
        else
            warn "网站文件不存在，正在创建..."
            setup_index_page
        fi

        # PHP 容器已就绪，回填面板密码 bcrypt 哈希 (安装面板时容器还没起)
        _f2b_finalize_hash

        save_progress "backup"
    fi
    
    # Stage: backup
    if [[ $stage_index -le 9 ]]; then
        setup_backup
        setup_cert_renewal
        setup_log_rotate
        save_credentials
        save_progress "done"
    fi
    
    clear_progress
    
    # 完成信息
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ${ICON_OK} ${BOLD}部署完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${ICON_GLOBE} ${BOLD}访问地址:${NC}"
    echo -e "     网站首页:     ${CYAN}https://$DOMAIN${NC}"
    for sub in "${SUBDOMAINS[@]}"; do
        echo -e "     子域名:       ${CYAN}https://${sub}.${DOMAIN}${NC}"
    done
    if [[ "${INSTALL_FAIL2BAN:-yes}" == "yes" ]]; then
        echo -e "     解封面板:     ${CYAN}https://$DOMAIN/f2b/${NC}  ${DIM}(fail2ban 网页管理，凭据见下)${NC}"
    fi
    if [[ "$INSTALL_PHPMYADMIN" == "yes" ]]; then
        echo -e "     phpMyAdmin:   ${CYAN}http://$DOMAIN:8080${NC}"
    fi
    echo ""
    echo -e "  ${ICON_DATABASE} ${BOLD}数据库:${NC}"
    echo -e "     主机: mysql (容器内)"
    echo -e "     用户: root"
    echo -e "     密码: 见 $CREDENTIALS_FILE"
    echo ""
    echo -e "  ${ICON_FOLDER} ${BOLD}文件位置:${NC}"
    echo -e "     项目目录: $PROJECT_DIR"
    echo -e "     网站目录: $PROJECT_DIR/volumes/php/www/"
    if [[ "$NGINX_TYPE" == "linuxserver" ]]; then
        echo -e "     Nginx配置: $PROJECT_DIR/volumes/nginx/config/nginx/site-confs/"
    else
        echo -e "     Nginx配置: $PROJECT_DIR/volumes/nginx/conf.d/"
    fi
    echo ""
    echo -e "  ${ICON_GEAR} ${BOLD}常用命令:${NC}"
    echo -e "     $0 --status    查看状态"
    echo -e "     $0 --logs      查看日志"
    echo -e "     $0 --restart   重启服务"
    echo -e "     $0 --backup    立即备份"
    echo ""
    # WAF / fail2ban / 解封面板信息 (仅在安装了 fail2ban 时展示)
    if [[ "${INSTALL_FAIL2BAN:-yes}" == "yes" ]]; then
        _print_f2b_summary
    else
        echo -e "  ${ICON_LOCK} ${BOLD}fail2ban:${NC} 未安装 ${DIM}(WAF 拦截与限流已启用；如需 IP 自动封禁+解封面板，运行 $0 --setup-waf)${NC}"
        echo ""
    fi
    echo -e "${DIM}  详细说明请查看: $README_FILE${NC}"
    echo ""
}

# ======================== 交互式主菜单 ========================
# 无参数运行时展示；选项复用已有的完整安装 / WAF 安装流程。
show_main_menu() {
    show_banner
    echo -e "  ${BOLD}请选择要执行的操作:${NC}"
    echo ""
    echo -e "    ${CYAN}1)${NC} 安装 LNMP        ${DIM}只装 Nginx + MySQL + PHP + Redis + SSL (不含 fail2ban)${NC}"
    echo -e "    ${CYAN}2)${NC} 安装 fail2ban    ${DIM}为现有部署启用 fail2ban + 网页解封面板${NC}"
    echo ""
    echo -e "    ${CYAN}0)${NC} 退出"
    echo ""
    echo -e "${DIM}  说明: 选 1 的 WAF 拦截与限流照常启用，仅不安装 fail2ban 自动封禁；${NC}"
    echo -e "${DIM}        装好 LNMP 后可随时选 2 (或运行 $0 --setup-waf) 补装 fail2ban。${NC}"
    echo -e "${DIM}        其它运维操作请用命令行参数，如 $0 --help${NC}"
    echo ""
    printf "${GREEN}  请输入选项 [0-2]: ${NC}"
    local choice; IFS= read -r choice || choice=""
    case "$choice" in
        1) INSTALL_FAIL2BAN="no"; run_full_install ;;
        2) cmd_setup_waf ;;
        0|"") echo -e "${DIM}  已退出${NC}"; exit 0 ;;
        *) error "无效选项: $choice" ;;
    esac
}

# ======================== 主入口 ========================
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            ;;
        --version|-v)
            show_version
            ;;
        --cert|-c)
            cmd_cert_only
            ;;
        --renew)
            cmd_renew
            ;;
        --reconfig)
            cmd_reconfig
            ;;
        --status)
            cmd_status
            ;;
        --restart)
            cmd_restart
            ;;
        --stop)
            cmd_stop
            ;;
        --logs)
            cmd_logs "${2:-}"
            ;;
        --backup)
            do_backup_now
            ;;
        --setup-cloud-backup)
            cmd_setup_cloud_backup
            ;;
        --info)
            cmd_info
            ;;
        --health)
            cmd_health
            ;;
        --add-subdomain)
            cmd_add_subdomain
            ;;
        --del-subdomain|--delete-subdomain)
            cmd_del_subdomain "${2:-}"
            ;;
        --add-proxy)
            cmd_add_proxy
            ;;
        --setup-waf)
            cmd_setup_waf
            ;;
        --f2b-status)
            cmd_f2b_status
            ;;
        --f2b-unban)
            cmd_f2b_unban "${2:-}"
            ;;
        --f2b-ban)
            cmd_f2b_ban "${2:-}"
            ;;
        --rebuild-nginx)
            cmd_rebuild_nginx
            ;;
        --rebuild-php)
            cmd_rebuild_php
            ;;
        --rebuild-mysql)
            cmd_rebuild_mysql
            ;;
        --reset-mysql-password|--reset-mysql-pass)
            cmd_reset_mysql_password
            ;;
        --reset-f2b-password|--reset-f2b-pass)
            cmd_reset_f2b_password
            ;;
        --update-f2b-panel)
            cmd_update_f2b_panel
            ;;
        --uninstall)
            cmd_uninstall
            ;;
        --upgrade)
            cmd_upgrade
            ;;
        --cleanup)
            cmd_cleanup
            ;;
        "")
            show_main_menu
            ;;
        *)
            error "未知选项: $1\n使用 --help 查看帮助"
            ;;
    esac
}

main "$@"
