#!/usr/bin/env bash
set -Eeuo pipefail

# frp-manager-lite 预构建镜像生产部署脚本
# 流程：先收集参数生成 /opt/frp-manager-lite/.env，再从 .env 读取变量部署面板、frps、Nginx。
# 不会在用户服务器构建镜像，也不需要源码仓库。
#
# 快速使用：
#   curl -fsSL https://raw.githubusercontent.com/bohu-t/lite-install/main/deploy-image-production.sh | sudo bash
#
# 默认从阿里云 ACR 公开仓库拉取镜像：
#   registry.cn-hangzhou.aliyuncs.com/dxlx/frp-manager-lite:latest
#
# 非交互示例：
#   PANEL_DOMAIN=panel.example.com PANEL_HTTPS_PORT=8443 FRPS_DOMAIN=frp.example.com \
#   FML_ADMIN_PASSWORD='change-me' FRP_AUTH_TOKEN='change-me-token' \
#   sudo -E bash scripts/deploy-image-production.sh

APP_NAME="frp-manager-lite"
APP_DIR="${APP_DIR:-/opt/frp-manager-lite}"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"
FRP_STABLE_VERSION="${FRP_STABLE_VERSION:-0.66.0}"
FRP_CHANNEL="${FRP_CHANNEL:-}"

log()   { printf '\033[1;34m[部署]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[警告]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请用 root 执行，例如：sudo bash scripts/deploy-image-production.sh"
    exit 1
  fi
}

require_supported_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu) return 0 ;;
    esac
  fi
  warn "本脚本主要在 Debian/Ubuntu 测试，当前系统可能不兼容，继续执行…"
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
  else
    set +o pipefail
    local v
    v="$(LC_ALL=C tr -dc 'A-Za-z0-9_=-' </dev/urandom | head -c 43)"
    set -o pipefail
    printf '%s' "$v"
  fi
}

url_encode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

resolve_panel_plugin_path() {
  local node_id encoded_token
  node_id="$(curl -fsS --connect-timeout 5 "http://127.0.0.1:${FML_PUBLISH_PORT}/api/nodes" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    nodes = data.get("nodes") or []
    default = next((n for n in nodes if n.get("name") == "default"), nodes[0] if nodes else {})
    print(default.get("id", ""))
except Exception:
    print("")
' 2>/dev/null || true)"
  encoded_token="$(url_encode "${FRP_AUTH_TOKEN}")"
  if [[ -n "${node_id}" ]]; then
    printf '/frp-plugin?node_id=%s&node_token=%s' "${node_id}" "${encoded_token}"
  else
    warn "未能从面板读取默认节点 ID，frps 插件路径暂用 /frp-plugin；单节点可用，多节点前请到面板下载对应 frps 配置替换"
    printf '/frp-plugin'
  fi
}

has_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] && { : </dev/tty; } 2>/dev/null
}

prompt_value() {
  local var_name="$1" prompt="$2" default_value="${3:-}"
  local current="${!var_name:-}"
  local effective_default="${current:-${default_value}}"
  local input

  # curl | sudo bash 时 stdin 是脚本内容，不是终端；必须显式从 /dev/tty 读取。
  if has_tty; then
    if [[ -n "${effective_default}" ]]; then
      read -r -p "${prompt} [${effective_default}]: " input < /dev/tty
      printf -v "${var_name}" '%s' "${input:-${effective_default}}"
    else
      read -r -p "${prompt}: " input < /dev/tty
      printf -v "${var_name}" '%s' "${input}"
    fi
  else
    printf -v "${var_name}" '%s' "${effective_default}"
  fi
}

prompt_secret() {
  local var_name="$1" prompt="$2"
  local current="${!var_name:-}"
  local generated input
  generated="$(random_secret)"

  # 有旧值时，回车保留；首次安装时，回车自动生成。
  if has_tty; then
    if [[ -n "${current}" ]]; then
      read -r -s -p "${prompt} [直接回车保留当前值]: " input < /dev/tty
      printf '\n' > /dev/tty
      printf -v "${var_name}" '%s' "${input:-${current}}"
    else
      read -r -s -p "${prompt} [直接回车自动生成]: " input < /dev/tty
      printf '\n' > /dev/tty
      printf -v "${var_name}" '%s' "${input:-${generated}}"
    fi
  else
    printf -v "${var_name}" '%s' "${current:-${generated}}"
  fi
}

resolve_latest_frp_version() {
  local latest
  latest="$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/fatedier/frp/releases/latest | python3 -c '
import json, sys
try:
    tag = json.load(sys.stdin).get("tag_name", "")
    print(tag[1:] if tag.startswith("v") else tag)
except Exception:
    sys.exit(1)
')" || { err "获取 frp 最新版失败，请检查网络或直接设置 FRP_VERSION"; exit 1; }
  [[ -n "$latest" ]] || { err "获取 frp 最新版失败：GitHub 返回为空"; exit 1; }
  printf '%s\n' "$latest"
}

select_frp_version() {
  if [[ -n "${FRP_VERSION:-}" ]]; then
    log "使用指定 frp 版本：${FRP_VERSION}"
    return 0
  fi

  local choice="${FRP_CHANNEL:-}"
  if [[ -z "$choice" ]]; then
    if has_tty; then
      echo '' > /dev/tty
      echo '请选择 frp 安装版本：' > /dev/tty
      echo "  1) 稳定版 v${FRP_STABLE_VERSION}（推荐）" > /dev/tty
      echo '  2) 最新版（自动读取 GitHub Releases）' > /dev/tty
      read -r -p '请选择 [1/2，默认 1]: ' choice < /dev/tty
      choice="${choice:-1}"
    else
      choice="stable"
    fi
  fi

  case "${choice,,}" in
    1|stable|stable版|稳定|稳定版)
      FRP_VERSION="$FRP_STABLE_VERSION"
      FRP_CHANNEL="stable"
      ;;
    2|latest|latest版|最新|最新版)
      FRP_VERSION="$(resolve_latest_frp_version)"
      FRP_CHANNEL="latest"
      ;;
    *)
      err "未知 frp 版本选项：${choice}（请输入 1/2、stable/latest，或直接设置 FRP_VERSION）"
      exit 1
      ;;
  esac
  log "frp 安装版本：${FRP_CHANNEL} → v${FRP_VERSION}"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

require_port() {
  local name="$1" value="${!1:-}"
  if ! valid_port "${value}"; then
    err "${name} 必须是 1-65535 的端口，当前：${value}"
    exit 1
  fi
}

env_value() {
  local v="${1:-}"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\$/\\\$}"
  v="${v//\`/\\\`}"
  printf '"%s"' "${v}"
}

write_env_var() {
  printf '%s=%s\n' "$1" "$(env_value "${2:-}")" >> "${ENV_FILE}"
}

load_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    err "找不到配置文件：${ENV_FILE}"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
}

collect_env_file() {
  mkdir -p "${APP_DIR}"

  if [[ -f "${ENV_FILE}" ]]; then
    log "检测到现有 ${ENV_FILE}，将作为默认值读取并备份。"
    load_env_file
    cp -a "${ENV_FILE}" "${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  IMAGE="${IMAGE:-registry.cn-hangzhou.aliyuncs.com/dxlx/frp-manager-lite:latest}"
  FRP_VERSION="${FRP_VERSION:-}"
  select_frp_version
  FML_PUBLISH_PORT="${FML_PUBLISH_PORT:-18081}"
  FML_ADMIN_USER="${FML_ADMIN_USER:-admin}"
  FML_DEFAULT_MAX_PORTS="${FML_DEFAULT_MAX_PORTS:-5}"
  FRPS_BIND_PORT="${FRPS_BIND_PORT:-7000}"
  FRPS_PORT_START="${FRPS_PORT_START:-20000}"
  FRPS_PORT_END="${FRPS_PORT_END:-20199}"
  FRPS_WEB_PORT="${FRPS_WEB_PORT:-7500}"
  ENABLE_PORT_RATE_LIMIT="${ENABLE_PORT_RATE_LIMIT:-1}"
  FML_RATE_LIMIT_IFACE="${FML_RATE_LIMIT_IFACE:-}"
  PANEL_DOMAIN="${PANEL_DOMAIN:-}"
  FRPS_DOMAIN="${FRPS_DOMAIN:-${FRP_SERVER_ADDR:-}}"
  PANEL_HTTPS_PORT="${PANEL_HTTPS_PORT:-443}"
  INSTALL_NGINX="${INSTALL_NGINX:-auto}"
  ENABLE_HTTPS="${ENABLE_HTTPS:-auto}"
  ENABLE_UFW="${ENABLE_UFW:-0}"

  echo ''
  echo '========================================'
  echo '  frp-manager-lite 镜像版一键生产部署'
  echo '========================================'
  echo ''
  echo '先收集部署参数并写入 .env，后续所有配置都从 .env 读取。'
  echo ''

  prompt_value PANEL_DOMAIN "① 面板域名（留空则不安装 Nginx/HTTPS，面板直连端口）" "${PANEL_DOMAIN}"
  prompt_value FML_PUBLISH_PORT "② 面板容器映射端口" "${FML_PUBLISH_PORT}"
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    prompt_value PANEL_HTTPS_PORT "③ 面板 HTTPS 端口（443 被占用可填 8443 等）" "${PANEL_HTTPS_PORT}"
  fi

  local detected_frps_domain="${FRPS_DOMAIN}"
  if [[ -z "${detected_frps_domain}" ]]; then
    detected_frps_domain="${PANEL_DOMAIN:-$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || hostname -f 2>/dev/null || hostname)}"
  fi
  prompt_value FRPS_DOMAIN "④ frps 域名或 IP（用户 frpc 连接地址）" "${detected_frps_domain}"
  prompt_value FRPS_BIND_PORT "⑤ frps 入口端口" "${FRPS_BIND_PORT}"
  prompt_value FRPS_PORT_START "⑥ 用户隧道端口池起始端口" "${FRPS_PORT_START}"
  prompt_value FRPS_PORT_END "⑦ 用户隧道端口池结束端口" "${FRPS_PORT_END}"
  prompt_value FRPS_WEB_PORT "⑧ frps 自带仪表盘本地端口" "${FRPS_WEB_PORT}"

  prompt_value FML_ADMIN_USER "⑨ 面板管理员用户名" "${FML_ADMIN_USER}"
  echo ''
  echo '密码输入时不会回显。直接回车会自动生成。'
  prompt_secret FML_ADMIN_PASSWORD "⑩ 面板管理员密码"
  prompt_secret FRP_AUTH_TOKEN "⑪ frps token"
  prompt_secret FRPS_WEB_PASSWORD "⑫ frps 仪表盘密码"
  echo ''

  if [[ -z "${FML_PUBLISH_BIND:-}" ]]; then
    if [[ -z "${PANEL_DOMAIN}" ]]; then FML_PUBLISH_BIND="0.0.0.0"; else FML_PUBLISH_BIND="127.0.0.1"; fi
  fi
  PANEL_PLUGIN_ADDR="${PANEL_PLUGIN_ADDR:-127.0.0.1:${FML_PUBLISH_PORT}}"
  FML_SETUP_KEY="${FML_SETUP_KEY:-$(random_secret)}"

  require_port FML_PUBLISH_PORT
  require_port FRPS_BIND_PORT
  require_port FRPS_PORT_START
  require_port FRPS_PORT_END
  require_port FRPS_WEB_PORT
  if [[ -n "${PANEL_DOMAIN}" ]]; then require_port PANEL_HTTPS_PORT; fi
  if (( FRPS_PORT_START > FRPS_PORT_END )); then
    err "端口池起始端口不能大于结束端口"
    exit 1
  fi

  : > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  {
    echo "# 由 scripts/deploy-image-production.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 修改本文件后，可重跑部署脚本或执行对应服务重启命令。"
  } >> "${ENV_FILE}"

  write_env_var APP_NAME "${APP_NAME}"
  write_env_var APP_DIR "${APP_DIR}"
  write_env_var IMAGE "${IMAGE}"
  write_env_var FRP_VERSION "${FRP_VERSION}"
  write_env_var PANEL_DOMAIN "${PANEL_DOMAIN}"
  write_env_var PANEL_HTTPS_PORT "${PANEL_HTTPS_PORT}"
  write_env_var INSTALL_NGINX "${INSTALL_NGINX}"
  write_env_var ENABLE_HTTPS "${ENABLE_HTTPS}"
  write_env_var ENABLE_UFW "${ENABLE_UFW}"
  write_env_var FML_PUBLISH_BIND "${FML_PUBLISH_BIND}"
  write_env_var FML_PUBLISH_PORT "${FML_PUBLISH_PORT}"
  write_env_var FML_ADMIN_USER "${FML_ADMIN_USER}"
  write_env_var FML_ADMIN_PASSWORD "${FML_ADMIN_PASSWORD}"
  write_env_var FML_DEFAULT_MAX_PORTS "${FML_DEFAULT_MAX_PORTS}"
  write_env_var FML_SETUP_KEY "${FML_SETUP_KEY}"
  write_env_var FML_PORT_START "${FRPS_PORT_START}"
  write_env_var FML_PORT_END "${FRPS_PORT_END}"
  write_env_var FRPS_DOMAIN "${FRPS_DOMAIN}"
  write_env_var FRPS_BIND_PORT "${FRPS_BIND_PORT}"
  write_env_var FRPS_PORT_START "${FRPS_PORT_START}"
  write_env_var FRPS_PORT_END "${FRPS_PORT_END}"
  write_env_var FRPS_WEB_PORT "${FRPS_WEB_PORT}"
  write_env_var FRPS_WEB_PASSWORD "${FRPS_WEB_PASSWORD}"
  write_env_var ENABLE_PORT_RATE_LIMIT "${ENABLE_PORT_RATE_LIMIT}"
  write_env_var FML_RATE_LIMIT_IFACE "${FML_RATE_LIMIT_IFACE}"
  write_env_var FRP_SERVER_ADDR "${FRPS_DOMAIN}"
  write_env_var FRP_SERVER_PORT "${FRPS_BIND_PORT}"
  write_env_var FRP_AUTH_TOKEN "${FRP_AUTH_TOKEN}"
  write_env_var PANEL_PLUGIN_ADDR "${PANEL_PLUGIN_ADDR}"

  log "部署参数已写入 ${ENV_FILE}"
  load_env_file
}

apt_install_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl tar gzip openssl lsb-release python3 iproute2 iptables
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Compose 已安装：$(docker compose version --short 2>/dev/null || docker compose version)"
    return 0
  fi
  log "正在安装 Docker Engine 和 Compose 插件…"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  docker compose version
}

maybe_registry_login() {
  # 当前默认镜像仓库是公开 ACR，不需要登录。
  # 如果以后改为私有仓库，可传入 ACR_USERNAME/ACR_PASSWORD；GHCR_TOKEN 兼容旧镜像。
  if [[ -n "${ACR_USERNAME:-}" && -n "${ACR_PASSWORD:-}" ]]; then
    local registry="${ACR_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
    log "检测到 ACR_USERNAME/ACR_PASSWORD，正在登录 ${registry}…"
    echo "${ACR_PASSWORD}" | docker login "${registry}" -u "${ACR_USERNAME}" --password-stdin
  elif [[ -n "${GHCR_TOKEN:-}" ]]; then
    log "检测到 GHCR_TOKEN，正在登录 ghcr.io…"
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER:-${GITHUB_ACTOR:-token}}" --password-stdin
  fi
}

write_panel_files() {
  mkdir -p "${APP_DIR}"
  cd "${APP_DIR}"

  cat > docker-compose.yml <<'EOF'
services:
  frp-manager-lite:
    image: ${IMAGE}
    pull_policy: always
    container_name: frp-manager-lite
    restart: unless-stopped
    env_file:
      - path: .env
        required: false
    environment:
      FML_HOST: 0.0.0.0
      FML_PORT: 8080
      FML_DB: /data/data.sqlite3
      FML_PANEL_VERSION: ${FML_PANEL_VERSION:-1.0.4}
    ports:
      - "${FML_PUBLISH_BIND:-127.0.0.1}:${FML_PUBLISH_PORT:-18081}:8080"
    volumes:
      - frp-manager-lite-data:/data
      - /etc/machine-id:/host/machine-id:ro
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/nodes', timeout=3).read()"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      resources:
        limits:
          memory: 256M

volumes:
  frp-manager-lite-data:
EOF
}

start_panel() {
  log "正在拉取并启动面板镜像：${IMAGE}"
  cd "${APP_DIR}"
  docker compose pull
  docker compose up -d
  log "等待面板健康检查就绪…"
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${FML_PUBLISH_PORT}/api/nodes" >/dev/null 2>&1; then
      log "面板已就绪：http://127.0.0.1:${FML_PUBLISH_PORT}"
      return 0
    fi
    sleep 2
  done
  warn "面板 60 秒内未就绪，请检查：cd ${APP_DIR} && docker compose logs --tail=100"
}

detect_system_arch() {
  SYSTEM_ARCH="$(uname -m)"
  case "${SYSTEM_ARCH}" in
    x86_64|amd64) FRP_ARCH="amd64" ;;
    aarch64|arm64) FRP_ARCH="arm64" ;;
    armv7l|armv7*) FRP_ARCH="arm" ;;
    armv6l|armv6*) FRP_ARCH="arm" ;;
    i386|i686) FRP_ARCH="386" ;;
    *) err "不支持的 CPU 架构：${SYSTEM_ARCH}"; exit 1 ;;
  esac
  log "系统架构检测通过：${SYSTEM_ARCH} → frp linux_${FRP_ARCH}"
}

frp_arch() {
  printf '%s\n' "${FRP_ARCH:?未检测系统架构}"
}

install_frps_binary() {
  local arch package url tmpdir
  arch="$(frp_arch)"
  package="frp_${FRP_VERSION}_linux_${arch}"
  url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${package}.tar.gz"
  tmpdir="$(mktemp -d)"

  if command -v frps >/dev/null 2>&1 && frps --version 2>/dev/null | grep -qx "${FRP_VERSION}"; then
    log "frps ${FRP_VERSION} 已安装，跳过下载"
    rm -rf "${tmpdir}"
    return 0
  fi

  log "正在下载 frps ${FRP_VERSION} (${arch})…"
  curl -fL "${url}" -o "${tmpdir}/frp.tar.gz"
  tar -xzf "${tmpdir}/frp.tar.gz" -C "${tmpdir}"
  install -m 0755 "${tmpdir}/${package}/frps" /usr/local/bin/frps
  rm -rf "${tmpdir}"
  log "frps 安装完成：$(/usr/local/bin/frps --version 2>/dev/null | sed 's/^/frps /')"
}

write_frps_config() {
  mkdir -p /etc/frp
  if [[ -f /etc/frp/frps.toml ]]; then
    cp -a /etc/frp/frps.toml "/etc/frp/frps.toml.bak.$(date +%Y%m%d-%H%M%S)"
    log "已备份原有 /etc/frp/frps.toml"
  fi

  local plugin_path
  plugin_path="$(resolve_panel_plugin_path)"

  cat > /etc/frp/frps.toml <<TOML
# 由 ${ENV_FILE} 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# frp ${FRP_VERSION}
bindPort = ${FRPS_BIND_PORT}

auth.method = "token"
auth.token = "${FRP_AUTH_TOKEN}"

allowPorts = [
  { start = ${FRPS_PORT_START}, end = ${FRPS_PORT_END} }
]

transport.tcpMux = true
transport.maxPoolCount = 5

webServer.addr = "127.0.0.1"
webServer.port = ${FRPS_WEB_PORT}
webServer.user = "admin"
webServer.password = "${FRPS_WEB_PASSWORD}"

[[httpPlugins]]
name = "frp-manager-lite-auth"
addr = "${PANEL_PLUGIN_ADDR}"
path = "${plugin_path}"
ops = ["Login", "NewProxy"]
TOML
  chmod 600 /etc/frp/frps.toml
}

install_frps_service() {
  cat > /etc/systemd/system/frps.service <<'SERVICE'
[Unit]
Description=frp server
Documentation=https://github.com/fatedier/frp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable --now frps
  systemctl restart frps
  log "frps 服务已启动：$(systemctl is-active frps)"
}

write_nginx_http_config() {
  mkdir -p /var/www/certbot
  cat > /etc/nginx/sites-available/frp-manager-lite <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    client_max_body_size 100m;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }

    location / {
        proxy_pass http://127.0.0.1:${FML_PUBLISH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
}

write_nginx_https_config() {
  local redirect_target="https://\$host\$request_uri"
  if [[ "${PANEL_HTTPS_PORT}" != "443" ]]; then
    redirect_target="https://\$host:${PANEL_HTTPS_PORT}\$request_uri"
  fi

  cat > /etc/nginx/sites-available/frp-manager-lite <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }

    location / {
        return 301 ${redirect_target};
    }
}

server {
    listen ${PANEL_HTTPS_PORT} ssl http2;
    server_name ${PANEL_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${FML_PUBLISH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX
}

install_nginx_if_requested() {
  local do_nginx="${INSTALL_NGINX}"
  if [[ "${do_nginx}" == "auto" ]]; then
    if [[ -n "${PANEL_DOMAIN}" ]]; then do_nginx="1"; else do_nginx="0"; fi
  fi
  [[ "${do_nginx}" == "1" ]] || return 0
  if [[ -z "${PANEL_DOMAIN}" ]]; then
    warn "INSTALL_NGINX=1 但 .env 未配置 PANEL_DOMAIN，跳过 Nginx"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y nginx
  if [[ -f /etc/nginx/sites-available/frp-manager-lite ]]; then
    cp -a /etc/nginx/sites-available/frp-manager-lite "/etc/nginx/sites-available/frp-manager-lite.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  write_nginx_http_config
  ln -sfn /etc/nginx/sites-available/frp-manager-lite /etc/nginx/sites-enabled/frp-manager-lite
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  log "Nginx HTTP 反向代理已配置 → http://${PANEL_DOMAIN}"

  local do_https="${ENABLE_HTTPS}"
  if [[ "${do_https}" == "auto" ]]; then do_https="1"; fi
  if [[ "${do_https}" == "1" ]]; then
    apt-get install -y certbot
    log "正在为 ${PANEL_DOMAIN} 申请 Let's Encrypt 证书（80 端口验证，HTTPS 监听 ${PANEL_HTTPS_PORT}）…"
    if certbot certonly --webroot -w /var/www/certbot -d "${PANEL_DOMAIN}" --non-interactive --agree-tos -m "admin@${PANEL_DOMAIN}"; then
      write_nginx_https_config
      nginx -t
      systemctl reload nginx
      log "Nginx HTTPS 已配置 → https://${PANEL_DOMAIN}$([[ "${PANEL_HTTPS_PORT}" == "443" ]] || printf ':%s' "${PANEL_HTTPS_PORT}")"
    else
      warn "证书申请失败，保留 HTTP 配置。请确认 DNS 和 80 端口后重试。"
    fi
  fi
}

install_port_rate_limit_sync() {
  if [[ "${ENABLE_PORT_RATE_LIMIT:-1}" != "1" ]]; then
    log "端口速率策略同步已关闭（ENABLE_PORT_RATE_LIMIT=${ENABLE_PORT_RATE_LIMIT:-0}）"
    systemctl disable --now fml-port-rate-limit.timer fml-port-rate-limit.service 2>/dev/null || true
    return 0
  fi

  cat > /usr/local/sbin/fml-sync-port-rate-limits <<'SYNC_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/frp-manager-lite}"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"
PANEL_URL="${PANEL_URL:-}"
FML_SETUP_KEY="${FML_SETUP_KEY:-}"
IFACE="${FML_RATE_LIMIT_IFACE:-}"
NODE_ID="${FML_RATE_LIMIT_NODE_ID:-}"
DRY_RUN="${DRY_RUN:-0}"
CLEAR="${CLEAR:-0}"

CHAIN="FML_RATE_LIMIT"
MARK_BASE="${FML_RATE_LIMIT_MARK_BASE:-42000}"
CLASS_BASE="${FML_RATE_LIMIT_CLASS_BASE:-4200}"
QDISC_HANDLE="${FML_RATE_LIMIT_QDISC_HANDLE:-42}"
DEFAULT_CLASS="${FML_RATE_LIMIT_DEFAULT_CLASS:-9999}"
DEFAULT_RATE="${FML_RATE_LIMIT_DEFAULT_RATE:-10000mbit}"
FORCE="${FML_RATE_LIMIT_FORCE:-0}"

log(){ printf '\033[1;34m[rate-limit]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[rate-limit] WARN:\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[rate-limit] ERROR:\033[0m %s\n' "$*" >&2; }
run(){ if [[ "$DRY_RUN" == "1" ]]; then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; exit 1; }; }

load_env(){
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
  PANEL_URL="${PANEL_URL:-http://127.0.0.1:${FML_PUBLISH_PORT:-18081}}"
  FML_SETUP_KEY="${FML_SETUP_KEY:-${FML_SETUP_KEY:-}}"
}

detect_iface(){
  if [[ -n "$IFACE" ]]; then return 0; fi
  IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -z "$IFACE" ]]; then
    IFACE="$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  fi
  [[ -n "$IFACE" ]] || { err "无法自动识别出口网卡，请设置 FML_RATE_LIMIT_IFACE=eth0"; exit 1; }
}

api_url(){
  local url="${PANEL_URL%/}/api/host/port-rate-rules"
  if [[ -n "$NODE_ID" ]]; then url="${url}?node_id=${NODE_ID}"; fi
  printf '%s' "$url"
}

fetch_rules(){
  local url tmp
  url="$(api_url)"
  tmp="$(mktemp)"
  if ! curl -fsS --connect-timeout 5 --max-time 20 -H "X-FML-Setup-Key: ${FML_SETUP_KEY}" "$url" -o "$tmp"; then
    rm -f "$tmp"
    err "拉取限速规则失败：$url"
    exit 1
  fi
  python3 - "$tmp" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, 'r', encoding='utf-8'))
if not data.get('ok'):
    raise SystemExit(data.get('error') or 'API returned ok=false')
for r in data.get('rules') or []:
    port = int(r.get('port') or 0)
    proto = str(r.get('protocol') or 'tcp').lower()
    rate = int(r.get('rate_kbit') or 0)
    if port > 0 and proto in {'tcp','udp'} and rate > 0:
        print(f'{port}\t{proto}\t{rate}')
PY
  rm -f "$tmp"
}

clear_rules(){
  run iptables -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null || true
  run iptables -t mangle -F "$CHAIN" 2>/dev/null || true
  run iptables -t mangle -X "$CHAIN" 2>/dev/null || true
  if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "qdisc htb ${QDISC_HANDLE}:"; then
    run tc qdisc del dev "$IFACE" root 2>/dev/null || true
  fi
}

guard_existing_qdisc(){
  local line
  line="$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$0 ~ / root / {print; exit}')"
  [[ -z "$line" ]] && return 0
  if grep -q "qdisc htb ${QDISC_HANDLE}:" <<< "$line"; then return 0; fi
  if [[ "$FORCE" == "1" ]]; then
    warn "将覆盖现有 root qdisc：$line"
    return 0
  fi
  if grep -Eq 'qdisc (fq_codel|pfifo_fast|noqueue) ' <<< "$line"; then
    warn "将替换系统默认 root qdisc：$line"
    return 0
  fi
  err "检测到已有自定义 root qdisc，默认不覆盖：$line；如确认可覆盖，设置 FML_RATE_LIMIT_FORCE=1"
  exit 1
}

ensure_base(){
  guard_existing_qdisc
  if [[ "$DRY_RUN" == "1" ]]; then
    run modprobe sch_htb
    run modprobe cls_fw
  else
    modprobe sch_htb 2>/dev/null || true
    modprobe cls_fw 2>/dev/null || true
  fi
  run iptables -t mangle -N "$CHAIN" 2>/dev/null || true
  run iptables -t mangle -F "$CHAIN"
  if ! iptables -t mangle -C OUTPUT -j "$CHAIN" >/dev/null 2>&1; then
    run iptables -t mangle -A OUTPUT -j "$CHAIN"
  fi
  run tc qdisc replace dev "$IFACE" root handle "${QDISC_HANDLE}:" htb default "$DEFAULT_CLASS"
  run tc class replace dev "$IFACE" parent "${QDISC_HANDLE}:" classid "${QDISC_HANDLE}:${DEFAULT_CLASS}" htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE"
}

apply_rules(){
  local rules count=0 idx=1
  rules="$(fetch_rules)"
  if [[ -z "$rules" ]]; then
    clear_rules
    log "没有需要应用的端口速率策略；已清空 ${CHAIN} 规则，未改动其他 qdisc。"
    return 0
  fi
  ensure_base
  while IFS=$'\t' read -r port proto rate_kbit; do
    [[ -n "$port" ]] || continue
    local mark classid
    mark=$((MARK_BASE + idx))
    classid=$((CLASS_BASE + idx))
    run tc class replace dev "$IFACE" parent "${QDISC_HANDLE}:" classid "${QDISC_HANDLE}:${classid}" htb rate "${rate_kbit}kbit" ceil "${rate_kbit}kbit"
    run tc filter replace dev "$IFACE" protocol ip parent "${QDISC_HANDLE}:" prio 10 handle "$mark" fw flowid "${QDISC_HANDLE}:${classid}"
    if [[ "$proto" == "tcp" ]]; then
      run iptables -t mangle -A "$CHAIN" -p tcp --sport "$port" -j MARK --set-mark "$mark"
    else
      run iptables -t mangle -A "$CHAIN" -p udp --sport "$port" -j MARK --set-mark "$mark"
    fi
    count=$((count + 1)); idx=$((idx + 1))
  done <<< "$rules"
  log "已应用 ${count} 条端口速率策略：iface=${IFACE}, qdisc=${QDISC_HANDLE}:, chain=${CHAIN}"
}

main(){
  [[ "$(id -u)" == "0" ]] || { err "请用 root 执行"; exit 1; }
  need_cmd curl; need_cmd python3; need_cmd ip; need_cmd tc; need_cmd iptables
  load_env
  [[ -n "$FML_SETUP_KEY" ]] || { err "缺少 FML_SETUP_KEY，请检查 ${ENV_FILE}"; exit 1; }
  detect_iface
  if [[ "$CLEAR" == "1" ]]; then clear_rules; log "已清理端口速率策略"; return 0; fi
  apply_rules
}

main "$@"
SYNC_SCRIPT
  chmod 0755 /usr/local/sbin/fml-sync-port-rate-limits

  cat > /etc/systemd/system/fml-port-rate-limit.service <<SERVICE
[Unit]
Description=Sync frp-manager-lite host port rate limits
After=network-online.target frps.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=APP_DIR=${APP_DIR}
Environment=ENV_FILE=${ENV_FILE}
ExecStart=/usr/local/sbin/fml-sync-port-rate-limits
SERVICE

  cat > /etc/systemd/system/fml-port-rate-limit.timer <<'TIMER'
[Unit]
Description=Run frp-manager-lite port rate-limit sync every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=fml-port-rate-limit.service

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable --now fml-port-rate-limit.timer
  systemctl start fml-port-rate-limit.service || warn "端口速率策略首次同步失败，可查看：journalctl -u fml-port-rate-limit.service -n 80"
  log "端口速率策略同步已启用：systemctl status fml-port-rate-limit.timer"
}

configure_ufw_if_requested() {
  [[ "${ENABLE_UFW}" == "1" ]] || return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ufw
  ufw allow OpenSSH || true
  ufw allow 80/tcp
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    ufw allow "${PANEL_HTTPS_PORT}/tcp"
  fi
  ufw allow "${FRPS_BIND_PORT}/tcp"
  ufw allow "${FRPS_PORT_START}:${FRPS_PORT_END}/tcp"
  ufw allow "${FRPS_PORT_START}:${FRPS_PORT_END}/udp"
  ufw --force enable
  ufw status verbose
}

print_summary() {
  echo ''
  echo '========================================'
  echo '  部署完成！'
  echo '========================================'
  echo ''
  echo '【配置文件】'
  echo "  ${ENV_FILE}"
  echo ''
  echo '【管理面板】'
  echo "  目录：      ${APP_DIR}"
  echo "  镜像：      ${IMAGE}"
  echo "  管理员账号：${FML_ADMIN_USER}"
  echo "  本机访问：  http://127.0.0.1:${FML_PUBLISH_PORT}"
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    if [[ "${PANEL_HTTPS_PORT}" == "443" ]]; then
      echo "  公网访问：  https://${PANEL_DOMAIN}"
    else
      echo "  公网访问：  https://${PANEL_DOMAIN}:${PANEL_HTTPS_PORT}"
    fi
  elif [[ "${FML_PUBLISH_BIND}" == "0.0.0.0" ]]; then
    local pub_ip
    pub_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || hostname -f)"
    echo "  公网访问：  http://${pub_ip}:${FML_PUBLISH_PORT}"
  fi
  echo ''
  echo '【frps】'
  echo "  配置文件：  /etc/frp/frps.toml"
  echo "  地址：      ${FRPS_DOMAIN}:${FRPS_BIND_PORT}"
  echo "  端口池：    ${FRPS_PORT_START}-${FRPS_PORT_END}（TCP/UDP）"
  echo "  frps 面板： http://127.0.0.1:${FRPS_WEB_PORT}"
  echo ''
  echo '【常用命令】'
  echo "  改配置：    nano ${ENV_FILE}"
  echo "  重新部署：  curl -fsSL https://raw.githubusercontent.com/bohu-t/lite-install/main/deploy-image-production.sh | sudo bash"
  echo "  面板升级：  cd ${APP_DIR} && docker compose pull && docker compose up -d"
  echo "  面板日志：  cd ${APP_DIR} && docker compose logs -f"
  echo "  frps 日志： journalctl -u frps -f"
  echo "  frps 重启： systemctl restart frps"
  echo "  端口限速：  systemctl status fml-port-rate-limit.timer"
  echo "  限速预览：  DRY_RUN=1 /usr/local/sbin/fml-sync-port-rate-limits"
  echo "  清理限速：  CLEAR=1 /usr/local/sbin/fml-sync-port-rate-limits"
  echo ''
  echo '【防火墙/安全组需放行】'
  echo "  ${FRPS_BIND_PORT}/tcp"
  echo "  ${FRPS_PORT_START}-${FRPS_PORT_END}/tcp"
  echo "  ${FRPS_PORT_START}-${FRPS_PORT_END}/udp"
  if [[ -n "${PANEL_DOMAIN}" ]]; then
    echo "  80/tcp"
    echo "  ${PANEL_HTTPS_PORT}/tcp"
  else
    echo "  ${FML_PUBLISH_PORT}/tcp"
  fi
  echo ''
}

main() {
  need_root
  detect_system_arch
  require_supported_os
  collect_env_file

  log "重新从 ${ENV_FILE} 读取部署变量…"
  load_env_file

  log "开始安装基础依赖…"
  apt_install_base
  install_docker
  maybe_registry_login
  write_panel_files
  start_panel
  install_frps_binary
  write_frps_config
  install_frps_service
  install_port_rate_limit_sync
  install_nginx_if_requested
  configure_ufw_if_requested
  print_summary
}

main "$@"
