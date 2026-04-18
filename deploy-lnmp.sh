#!/usr/bin/env bash
set -eo pipefail

# ======================== 版本和配置 ========================
VERSION="2.2.0"
SCRIPT_URL="https://raw.githubusercontent.com/your-repo/lnmp-docker/main/deploy-lamp.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/lnmp"
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
    # Cross-platform disk space check
    if df -m "$SCRIPT_DIR" &>/dev/null; then
        available_mb=$(df -m "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    else
        # Fallback: use df without -m and convert from KB or blocks
        available_mb=$(df "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
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

get_php_pm_max_children() {
    case "$SERVER_TIER" in
        low)    echo "10" ;;
        medium) echo "25" ;;
        high)   echo "50" ;;
        ultra)
            local max_children=$(( SERVER_CPU_CORES * 10 ))
            [[ $max_children -lt 50 ]] && max_children=50
            [[ $max_children -gt 200 ]] && max_children=200
            echo "$max_children"
            ;;
    esac
}

get_php_pm_start_servers() {
    local max_children=$(get_php_pm_max_children)
    echo $(( max_children / 5 ))
}

get_php_pm_min_spare() {
    local max_children=$(get_php_pm_max_children)
    echo $(( max_children / 5 ))
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

# ======================== 进度管理 ========================
save_progress() {
    local stage=$1
    mkdir -p "$PROJECT_DIR"
    # 正确保存数组格式
    local subdomains_str=""
    for sub in "${SUBDOMAINS[@]}"; do
        subdomains_str+="\"$sub\" "
    done
    cat > "$PROGRESS_FILE" << EOFPROG
STAGE=$stage
DOMAIN=$DOMAIN
CERT_TYPE=$CERT_TYPE
DNS_PROVIDER=$DNS_PROVIDER
MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS
PHP_VERSION=$PHP_VERSION
INSTALL_PHPMYADMIN=$INSTALL_PHPMYADMIN
SUBDOMAINS=(${subdomains_str})
EOFPROG
}

load_progress() { [[ -f "$PROGRESS_FILE" ]] && source "$PROGRESS_FILE" && return 0; return 1; }
clear_progress() { rm -f "$PROGRESS_FILE"; }

# ======================== 显示函数 ========================
show_banner() {
    clear
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
    echo -e "  ${CYAN}--info${NC}           显示当前配置信息"
    echo -e "  ${CYAN}--health${NC}         健康检查"
    echo ""
    echo -e "${BOLD}高级操作:${NC}"
    echo -e "  ${CYAN}--add-subdomain${NC}  添加新子域名"
    echo -e "  ${CYAN}--rebuild-php${NC}    重新构建 PHP 镜像 (可选择版本)"
    echo -e "  ${CYAN}--rebuild-mysql${NC}  重建 MySQL/MariaDB (可选择版本)"
    echo -e "  ${CYAN}--uninstall${NC}      卸载并清理所有数据"
    echo -e "  ${CYAN}--upgrade${NC}        升级脚本到最新版本"
    echo -e "  ${CYAN}--cleanup${NC}        清理未使用的 Docker 资源"
    echo ""
    echo -e "${BOLD}其他:${NC}"
    echo -e "  ${CYAN}--help, -h${NC}       显示此帮助信息"
    echo -e "  ${CYAN}--version, -v${NC}    显示版本号"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${ICON_DATABASE} MySQL/MariaDB 操作指南${NC}"
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
        source /etc/os-release
        info "操作系统: $NAME $VERSION_ID"
        case "$ID" in
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
    check_disk_space 2000 || warn "建议至少保留 2GB 磁盘空间"
    
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
            printf "${GREEN}  请输入 MySQL root 密码: ${NC}"
            IFS= read -r MYSQL_ROOT_PASS || MYSQL_ROOT_PASS=""
            echo ""
            if [[ -z "$MYSQL_ROOT_PASS" ]]; then
                MYSQL_ROOT_PASS=$(generate_strong_password)
                echo -e "  ${YELLOW}${ICON_WARN}${NC} 密码为空，已自动生成强密码"
            else
                echo -e "  ${GREEN}${ICON_OK}${NC} 密码已设置"
            fi
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
    
    log "数据库配置完成"
}

# ======================== 目录和文件生成 ========================
setup_directories() {
    step "${ICON_FOLDER} 创建目录结构"
    
    local dirs=(
        "$PROJECT_DIR/volumes/nginx/conf.d"
        "$PROJECT_DIR/volumes/nginx/ssl"
        "$PROJECT_DIR/volumes/php/www/$DOMAIN"
        "$PROJECT_DIR/volumes/php/logs"
        "$PROJECT_DIR/volumes/mysql/conf.d"
        "$PROJECT_DIR/volumes/mysql/data"
        "$PROJECT_DIR/volumes/redis"
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
# 生成优化的 Nginx 主配置
setup_nginx_main_config() {
    step "${ICON_GEAR} 创建 Nginx 主配置 (性能优化)"
    
    # 获取动态参数
    local worker_connections=$(get_nginx_worker_connections)
    local client_body_buffer=$(get_nginx_client_body_buffer)
    
    cat > "$PROJECT_DIR/volumes/nginx/nginx.conf" << EOFNGINXMAIN
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

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';

    access_log /var/log/nginx/access.log main buffer=16k flush=2m;

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

    # 限流配置 (防止 DDoS)
    limit_req_zone \$binary_remote_addr zone=req_limit:10m rate=10r/s;
    limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

    # 包含虚拟主机配置
    include /etc/nginx/conf.d/*.conf;
}
EOFNGINXMAIN

    log "Nginx 主配置创建完成 (worker_connections=${worker_connections})"
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

    cat > "$PROJECT_DIR/docker-compose.yml" << EOFDC
services:
  nginx:
    image: nginx:alpine
    container_name: \${PROJECT_NAME}_nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./volumes/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./volumes/nginx/conf.d:/etc/nginx/conf.d
      - ./volumes/nginx/ssl:/etc/nginx/ssl
      - ./volumes/php/www:/var/www/html
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    depends_on:
      php:
        condition: service_started
    networks:
      - default
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

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
    environment:
      - MYSQL_HOST=mysql
      - MYSQL_DATABASE=\${MYSQL_DB}
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASS}
      - REDIS_HOST=redis
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
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=\${MYSQL_DB}
    volumes:
      - ./volumes/mysql/data:/var/lib/mysql
      - ./volumes/mysql/conf.d:/etc/mysql/conf.d:ro
    networks:
      - default
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -uroot -p$$MYSQL_ROOT_PASSWORD 2>/dev/null || mariadb-admin ping -h localhost -uroot -p$$MYSQL_ROOT_PASSWORD 2>/dev/null || healthcheck.sh --connect 2>/dev/null"]
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
    command: redis-server --appendonly yes --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes:
      - ./volumes/redis:/data
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
EOFENV
    # 安全优化: 设置 .env 文件权限为仅 root 可读
    chmod 600 "$PROJECT_DIR/.env"

    log "Docker Compose 配置生成完成"
}

setup_nginx_initial() {
    step "${ICON_GEAR} 配置 Nginx (初始化)"
    
    # HTTP 重定向配置
    cat > "$PROJECT_DIR/volumes/nginx/conf.d/00-http-redirect.conf" << 'EOFNGINX'
server {
    listen 80 default_server;
    server_name _;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://$host$request_uri;
    }
}
EOFNGINX
    log "Nginx 初始配置完成"
}

setup_nginx_final() {
    step "${ICON_GEAR} 配置 Nginx (HTTPS)"
    
    local ssl_cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    local config_index=1
    
    # 主域名配置
    cat > "$PROJECT_DIR/volumes/nginx/conf.d/0${config_index}-${DOMAIN}.conf" << EOFMAIN
server {
    listen 443 ssl;
    http2 on;
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
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

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
        
        cat > "$PROJECT_DIR/volumes/nginx/conf.d/0${config_index}-${sub}.conf" << EOFSUB
server {
    listen 443 ssl;
    http2 on;
    server_name ${sub}.${DOMAIN};
    root /var/www/html/${sub}.${DOMAIN};
    index index.php index.html index.htm;

    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

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
        
        # 创建默认欢迎页
        cat > "$sub_dir/index.html" << EOFHTML
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>${sub}.${DOMAIN}</title>
<style>body{font-family:system-ui;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;text-align:center}</style>
</head><body><div><h1>${ICON_ROCKET} ${sub}.${DOMAIN}</h1><p>LNMP Stack Ready!</p></div></body></html>
EOFHTML
    done
    
    log "Nginx HTTPS 配置完成 (共 $config_index 个配置文件)"
}

setup_index_page() {
    step "${ICON_GEAR} 创建 PHP 欢迎页"
    
    # 确保目录存在
    local web_dir="$PROJECT_DIR/volumes/php/www/$DOMAIN"
    mkdir -p "$web_dir"
    
    cat > "$web_dir/index.php" << 'EOFPHP'
<?php
$redis_status = "未连接";
try {
    $redis = new Redis();
    if ($redis->connect('redis', 6379)) {
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
        domains="-d $DOMAIN -d *.$DOMAIN"
        
        case "$DNS_PROVIDER" in
            cloudflare)
                mkdir -p "$PROJECT_DIR/certbot/conf"
                echo "dns_cloudflare_api_token = $CF_TOKEN" > "$PROJECT_DIR/certbot/conf/cloudflare.ini"
                chmod 600 "$PROJECT_DIR/certbot/conf/cloudflare.ini"
                
                info "使用 Cloudflare DNS 验证申请通配符证书..."
                docker run --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" \
                    certbot/dns-cloudflare certonly --dns-cloudflare \
                    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
                    --dns-cloudflare-propagation-seconds 30 \
                    $domains --email "admin@$DOMAIN" --agree-tos --non-interactive \
                    || { show_cert_retry_hint; return 1; }
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
                    docker run -it --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" \
                        certbot/certbot certonly --manual --preferred-challenges dns \
                        $domains --email "admin@$DOMAIN" --agree-tos \
                        || { show_cert_retry_hint; return 1; }
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
                    docker run -it --rm -v "$PROJECT_DIR/certbot/conf:/etc/letsencrypt" \
                        certbot/certbot certonly --manual --preferred-challenges dns \
                        $domains --email "admin@$DOMAIN" --agree-tos \
                        || { show_cert_retry_hint; return 1; }
                else
                    return 1
                fi
                ;;
        esac
    else
        # 单域名证书使用 HTTP-01 验证
        info "启动 Nginx 进行 HTTP-01 验证..."
        docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d nginx
        
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
        network_name=$(docker network ls --filter "name=${PROJECT_NAME}" --format '{{.Name}}' | grep -E '_default$|_net$' | head -1)
        if [[ -z "$network_name" ]]; then
            # Fallback: try to get network from running container
            network_name=$(docker inspect "${PROJECT_NAME}_nginx" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)
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
if docker compose run --rm certbot renew --quiet 2>> "$LOG_FILE"; then
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

# 备份数据库 (兼容 MariaDB 和 MySQL)
# MariaDB 10.5+ 使用 mariadb-dump，旧版本和 MySQL 使用 mysqldump
DUMP_CMD="mariadb-dump"
if ! docker exec lnmp_mysql command -v mariadb-dump &>/dev/null; then
    DUMP_CMD="mysqldump"
fi

if docker exec lnmp_mysql $DUMP_CMD -uroot -p"$MYSQL_ROOT_PASS" --all-databases > "$BACKUP_DIR/db_$DATE.sql" 2>/dev/null; then
    echo "[$(date)] 数据库备份成功: db_$DATE.sql (使用 $DUMP_CMD)"
else
    echo "[$(date)] 数据库备份失败"
fi

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
PHP 版本: $PHP_VERSION
# ==========================================
EOFCRED
    chmod 600 "$CREDENTIALS_FILE"
    
    # README
    cat > "$README_FILE" << EOFREADME
# LNMP Docker 部署

## 目录结构
\`\`\`
$PROJECT_DIR/
├── docker-compose.yml
├── volumes/
│   ├── nginx/conf.d/    # Nginx 配置
│   ├── php/www/         # 网站文件
│   ├── mysql/
│   │   ├── data/        # 数据库数据文件
│   │   └── conf.d/      # 数据库配置
│   └── redis/           # Redis 数据
├── certbot/             # SSL 证书
└── backups/             # 备份文件
\`\`\`

## 常用命令
\`\`\`bash
# 查看状态
$0 --status

# 重启服务
$0 --restart

# 查看日志
$0 --logs nginx

# 手动备份
$0 --backup

# 续期证书
$0 --renew
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
    
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        error "请先完成初始安装"
    fi
    source "$PROJECT_DIR/.env"
    
    printf "${GREEN}  请输入新子域名 (不含主域名): ${NC}"
    IFS= read -r new_sub || new_sub=""
    [[ -z "$new_sub" ]] && error "子域名不能为空"
    
    local sub_dir="$PROJECT_DIR/volumes/php/www/${new_sub}.${DOMAIN}"
    mkdir -p "$sub_dir"
    
    local ssl_cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    local config_num=$(ls -1 "$PROJECT_DIR/volumes/nginx/conf.d/" | wc -l)
    config_num=$((config_num + 1))
    
    cat > "$PROJECT_DIR/volumes/nginx/conf.d/0${config_num}-${new_sub}.conf" << EOFNEWSUB
server {
    listen 443 ssl;
    http2 on;
    server_name ${new_sub}.${DOMAIN};
    root /var/www/html/${new_sub}.${DOMAIN};
    index index.php index.html;

    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

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

    # 重载 Nginx
    cd "$PROJECT_DIR"
    docker compose exec nginx nginx -s reload
    
    log "子域名 ${new_sub}.${DOMAIN} 添加成功"
    info "网站目录: $sub_dir"
    warn "如果使用单域名证书，需要重新申请证书以包含新子域名"
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
    
    if [[ "$build_type" == "1" ]]; then
        docker compose build php
    else
        docker compose build --no-cache php
    fi
    
    local build_status=$?
    
    if [[ $build_status -eq 0 ]]; then
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

cmd_uninstall() {
    step "${ICON_WARN} 卸载确认"
    echo ""
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
    
    # 删除 crontab 任务 (only remove lines containing backup_task.sh or renew-cert.sh from this project)
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "$PROJECT_DIR/backup_task.sh" | grep -v "$PROJECT_DIR/renew-cert.sh" > "$temp_cron" 2>/dev/null || true
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"
    
    # 备份凭据
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        cp "$CREDENTIALS_FILE" "$SCRIPT_DIR/credentials_backup_$(date +%Y%m%d).txt"
        info "凭据已备份到 $SCRIPT_DIR/"
    fi
    
    # 删除目录
    rm -rf "$PROJECT_DIR"
    
    log "卸载完成"
}

cmd_cert_only() {
    show_banner
    step "${ICON_LOCK} 重新申请 SSL 证书"
    
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        # 首次申请，需要收集信息
        collect_domain_info
        select_cert_type
    else
        source "$PROJECT_DIR/.env"
        source "$PROGRESS_FILE" 2>/dev/null || true
    fi
    
    obtain_ssl_certificate || exit 1
    setup_nginx_final
    
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
    local remote_version=""
    local temp_script=$(mktemp)
    
    info "检查最新版本..."
    if curl -fsSL --connect-timeout 10 "$SCRIPT_URL" -o "$temp_script" 2>/dev/null; then
        remote_version=$(grep -m1 '^VERSION=' "$temp_script" | cut -d'"' -f2)
        
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
        
        version_compare "$VERSION" "$remote_version"
        local cmp_result=$?
        
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
    if docker compose run --rm certbot renew; then
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

# ======================== 主安装流程 ========================
run_full_install() {
    show_banner
    
    # 检查是否可以恢复
    if load_progress; then
        echo ""
        info "检测到未完成的安装 (阶段: $STAGE)"
        printf "${GREEN}  是否继续上次安装? [Y/n]: ${NC}"
        IFS= read -r resume || resume=""
        if [[ ! "$resume" =~ ^[Nn]$ ]]; then
            info "恢复安装..."
        else
            clear_progress
            STAGE=""
        fi
    fi
    
    local stages=("env" "docker" "config" "dirs" "compose" "nginx_init" "cert" "nginx_final" "services" "backup" "done")
    local current_stage=${STAGE:-env}
    local stage_index=0
    
    for i in "${!stages[@]}"; do
        [[ "${stages[$i]}" == "$current_stage" ]] && stage_index=$i && break
    done
    
    # Stage: env
    if [[ $stage_index -le 0 ]]; then
        check_env
        detect_server_config
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
        setup_nginx_main_config
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
        docker compose up -d
        
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
        
        save_progress "backup"
    fi
    
    # Stage: backup
    if [[ $stage_index -le 9 ]]; then
        setup_backup
        setup_cert_renewal
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
    echo -e "     https://$DOMAIN"
    for sub in "${SUBDOMAINS[@]}"; do
        echo -e "     https://${sub}.${DOMAIN}"
    done
    echo ""
    echo -e "  ${ICON_DATABASE} ${BOLD}数据库:${NC}"
    echo -e "     主机: mysql (容器内)"
    echo -e "     用户: root"
    echo -e "     密码: 见 $CREDENTIALS_FILE"
    echo ""
    echo -e "  ${ICON_FOLDER} ${BOLD}文件位置:${NC}"
    echo -e "     项目目录: $PROJECT_DIR"
    echo -e "     网站目录: $PROJECT_DIR/volumes/php/www/"
    echo -e "     Nginx配置: $PROJECT_DIR/volumes/nginx/conf.d/"
    echo ""
    echo -e "  ${ICON_GEAR} ${BOLD}常用命令:${NC}"
    echo -e "     $0 --status    查看状态"
    echo -e "     $0 --logs      查看日志"
    echo -e "     $0 --restart   重启服务"
    echo -e "     $0 --backup    立即备份"
    echo ""
    echo -e "${DIM}  详细说明请查看: $README_FILE${NC}"
    echo ""
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
        --info)
            cmd_info
            ;;
        --health)
            cmd_health
            ;;
        --add-subdomain)
            cmd_add_subdomain
            ;;
        --rebuild-php)
            cmd_rebuild_php
            ;;
        --rebuild-mysql)
            cmd_rebuild_mysql
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
            run_full_install
            ;;
        *)
            error "未知选项: $1\n使用 --help 查看帮助"
            ;;
    esac
}

main "$@"
