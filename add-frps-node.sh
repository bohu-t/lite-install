#!/usr/bin/env bash
set -Eeuo pipefail

# frp-manager-lite 一键添加 frps 节点（小白友好版）
# 在新的 VPS 上运行，全中文交互，零脑力。
#
# 直接用 curl 下载运行即可：
#   curl -fsSL https://raw.githubusercontent.com/.../add-frps-node.sh | bash
#
# 高级用户也可用环境变量跳过交互：
#   PANEL_URL=... SETUP_KEY=... NODE_NAME=hk-01 bash add-frps-node.sh

FRP_STABLE_VERSION="${FRP_STABLE_VERSION:-0.66.0}"
FRP_VERSION="${FRP_VERSION:-}"
FRP_CHANNEL="${FRP_CHANNEL:-}"
NODE_NAME="${NODE_NAME:-}"
REGION="${REGION:-}"
FRPS_BIND_PORT="${FRPS_BIND_PORT:-7000}"
FRPS_TOKEN="${FRPS_TOKEN:-}"
PORT_START="${PORT_START:-}"
PORT_END="${PORT_END:-}"
FRPS_DASHBOARD_PORT="${FRPS_DASHBOARD_PORT:-7500}"
FRPS_DASHBOARD_USER="${FRPS_DASHBOARD_USER:-admin}"
FRPS_DASHBOARD_PWD="${FRPS_DASHBOARD_PWD:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}✅${NC} $*"; }
warn() { echo -e "${YELLOW}⚠️${NC}  $*"; }
err()  { echo -e "${RED}❌${NC} $*"; exit 1; }

# `curl ... | sudo bash` 会把 stdin 用作脚本内容；交互输入必须从控制终端读取，
# 否则 read 会把后续脚本源码当成用户输入。
if [[ -r /dev/tty ]]; then
  exec 3</dev/tty
else
  exec 3<&0
fi

ask() {
  local __var="$1"
  local __prompt="$2"
  local __value=""
  if [[ ! -t 3 ]]; then
    err "当前没有可交互终端，请改用环境变量传参或在终端中运行脚本"
  fi
  read -r -p "$__prompt" __value <&3
  printf -v "$__var" '%s' "$__value"
}

ask_secret() {
  local __var="$1"
  local __prompt="$2"
  local __value=""
  if [[ ! -t 3 ]]; then
    err "当前没有可交互终端，请改用环境变量传参或在终端中运行脚本"
  fi
  read -r -s -p "$__prompt" __value <&3
  echo
  printf -v "$__var" '%s' "$__value"
}

url_encode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
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
')" || err "获取 frp 最新版失败，请检查网络或直接设置 FRP_VERSION"
  [[ -n "$latest" ]] || err "获取 frp 最新版失败：GitHub 返回为空"
  printf '%s\n' "$latest"
}

select_frp_version() {
  if [[ -n "$FRP_VERSION" ]]; then
    log "使用指定 frp 版本：${FRP_VERSION}"
    return 0
  fi

  local choice="${FRP_CHANNEL}"
  if [[ -z "$choice" ]]; then
    if [[ -t 3 ]]; then
      echo ''
      echo -e "${CYAN}━━━ 第 0 步：选择 frp 版本 ━━━${NC}"
      echo "  1) 稳定版 v${FRP_STABLE_VERSION}（推荐）"
      echo "  2) 最新版（自动读取 GitHub Releases）"
      ask choice "  请选择 [1/2，默认 1]："
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
      ;;
  esac
  log "frp 安装版本：${FRP_CHANNEL} → v${FRP_VERSION}"
}


detect_system_arch() {
  SYSTEM_ARCH="$(uname -m)"
  case "$SYSTEM_ARCH" in
    x86_64|amd64) FRP_ARCH="amd64" ;;
    aarch64|arm64) FRP_ARCH="arm64" ;;
    armv7l|armv7*) FRP_ARCH="arm" ;;
    armv6l|armv6*) FRP_ARCH="arm" ;;
    i386|i686) FRP_ARCH="386" ;;
    *) err "不支持的 CPU 架构：${SYSTEM_ARCH}（支持 x86_64/amd64、arm64/aarch64、armv6/armv7、i386/i686）" ;;
  esac
  log "系统架构检测通过：${SYSTEM_ARCH} → frp linux_${FRP_ARCH}"
}

# ── 交互式引导 ──────────────────────────────────────────────

detect_system_arch
select_frp_version

echo ''
echo -e "${CYAN}  ╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║   frp-manager-lite · 添加 frps 节点  ║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════╝${NC}"
echo ''
echo '  本脚本会：'
echo '    ① 向你的面板注册新节点'
echo '    ② 安装并启动 frps'
echo '    ③ 配置 systemd 开机自启'
echo '    ④ 接入面板监控并安装端口限速同步'
echo ''
echo '  需要提前准备：'
echo '    · 面板地址（如 https://panel.example.com）'
echo '    · 面板后台 → 仪表盘 → 运维入口 → FML_SETUP_KEY'
echo '    · 本机公网 IP 已开放对应端口（防火墙 / 安全组）'
echo ''

# ── 第 1 步：面板连接信息 ──────────────────────────────────

PANEL_URL="${PANEL_URL:-}"
SETUP_KEY="${SETUP_KEY:-}"

echo -e "${CYAN}━━━ 第 1 步：连接你的面板 ━━━${NC}"
echo ''

while [[ -z "$PANEL_URL" ]]; do
  ask PANEL_URL "  面板地址（例如 https://panel.example.com）："
done
if [[ "$PANEL_URL" =~ /$ ]]; then PANEL_URL="${PANEL_URL%/}"; fi

while [[ -z "$SETUP_KEY" ]]; do
  ask_secret SETUP_KEY "  FML_SETUP_KEY（在面板后台 → 仪表盘 → 运维入口查看，不回显）："
  SETUP_KEY="$(echo "$SETUP_KEY" | tr -d '[:space:]')"
  if [[ ${#SETUP_KEY} -lt 8 ]]; then
    echo '  ❌ 密钥太短，至少 8 位'
    SETUP_KEY=""
  fi
done

# 检查面板连通性
echo ''
log "正在连接面板 ${PANEL_URL} …"
if ! curl -fsS --connect-timeout 5 "${PANEL_URL}/api/csrf" >/dev/null 2>&1; then
  warn "面板连接失败，但继续执行（可能是 HTTPS / 网络问题）"
fi

# ── 第 2 步：节点信息 ──────────────────────────────────────

echo ''
echo -e "${CYAN}━━━ 第 2 步：节点信息 ━━━${NC}"
echo ''

# 自动检测公网 IP
SERVER_IP="${SERVER_IP:-}"
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(curl -fsS --connect-timeout 5 ifconfig.me 2>/dev/null || \
                curl -fsS --connect-timeout 5 ipinfo.io/ip 2>/dev/null || \
                hostname -I 2>/dev/null | awk '{print $1}' || echo "")"
fi

while [[ -z "$NODE_NAME" ]]; do
  ask NODE_NAME "  节点名称（英文，如 hk-01、jp-tokyo-01）："
done

while [[ -z "$REGION" ]]; do
  ask REGION "  地区名称（如 香港、东京、洛杉矶）："
done

while [[ -z "$SERVER_IP" ]]; do
  ask SERVER_IP "  本机公网 IP："
done
echo -e "  → 公网 IP：${GREEN}${SERVER_IP}${NC}"

# ── 第 3 步：端口配置 ──────────────────────────────────────

echo ''
echo -e "${CYAN}━━━ 第 3 步：端口配置 ━━━${NC}"
echo ''

while [[ -z "$FRPS_BIND_PORT" ]] || ! [[ "$FRPS_BIND_PORT" =~ ^[0-9]+$ ]]; do
  ask FRPS_BIND_PORT "  frps 通信端口 [7000]："
  FRPS_BIND_PORT="${FRPS_BIND_PORT:-7000}"
done

while [[ -z "$FRPS_TOKEN" ]]; do
  ask_secret FRPS_TOKEN "  frps 鉴权 token（至少 6 位，不回显）："
  if [[ ${#FRPS_TOKEN} -lt 6 ]]; then
    echo '  ❌ token 至少 6 位'
    FRPS_TOKEN=""
  fi
done

while [[ -z "$PORT_START" ]] || ! [[ "$PORT_START" =~ ^[0-9]+$ ]]; do
  ask PORT_START "  用户端口池起始（例如 30000）："
done

while [[ -z "$PORT_END" ]] || ! [[ "$PORT_END" =~ ^[0-9]+$ ]]; do
  ask PORT_END "  用户端口池结束（例如 30199）："
done

if [[ $PORT_END -le $PORT_START ]]; then
  err "端口池范围不合法：${PORT_START}-${PORT_END}，结束必须大于起始"
fi

PORT_COUNT=$((PORT_END - PORT_START + 1))
if [[ $PORT_COUNT -gt 20000 ]]; then
  err "端口池太大（${PORT_COUNT} 个），单节点最多 20000 个端口"
fi
echo -e "  → 端口池：${PORT_START}-${PORT_END}（共 ${PORT_COUNT} 个）"

# ── dashboard 凭据 ───────────────────────────────────────────

if [[ -z "$FRPS_DASHBOARD_PWD" ]]; then
  FRPS_DASHBOARD_PWD="$(openssl rand -base64 12 2>/dev/null || python3 -c "import secrets; print(secrets.token_urlsafe(12))")"
fi
DASHBOARD_URL="${DASHBOARD_URL:-http://${SERVER_IP}:${FRPS_DASHBOARD_PORT}}"

# ── 第 4 步：注册到面板 ────────────────────────────────────

echo ''
echo -e "${CYAN}━━━ 第 4 步：注册到面板 ━━━${NC}"
log "正在注册节点 ${NODE_NAME}（${REGION}）…"

PAYLOAD="$(python3 -c "
import json, sys
print(json.dumps({
    'setup_key': sys.argv[1],
    'name': sys.argv[2],
    'region': sys.argv[3],
    'server_addr': sys.argv[4],
    'server_port': int(sys.argv[5]),
    'auth_token': sys.argv[6],
    'port_start': int(sys.argv[7]),
    'port_end': int(sys.argv[8]),
    'web_port': int(sys.argv[9]),
    'dashboard_url': sys.argv[10],
    'dashboard_user': sys.argv[11],
    'dashboard_password': sys.argv[12]
}, ensure_ascii=False))
" "$SETUP_KEY" "$NODE_NAME" "$REGION" "$SERVER_IP" "$FRPS_BIND_PORT" "$FRPS_TOKEN" "$PORT_START" "$PORT_END" "$FRPS_DASHBOARD_PORT" "$DASHBOARD_URL" "$FRPS_DASHBOARD_USER" "$FRPS_DASHBOARD_PWD")"

API_RESP="$(set +e; curl -sS --connect-timeout 10 -X POST "${PANEL_URL}/api/setup/register-node" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")"

if echo "$API_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null; then
  NODE_ID="$(echo "$API_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('node_id',''))")"
  log "面板注册成功！节点 ID：${NODE_ID}"
else
  echo ''
  err "面板返回：${API_RESP}"
fi

# ── 第 5 步：安装 frps ────────────────────────────────────

echo ''
echo -e "${CYAN}━━━ 第 5 步：安装 frps ━━━${NC}"

FRPS_DIR="/opt/frps-${NODE_NAME}"
mkdir -p "${FRPS_DIR}"

NEED_INSTALL_FRPS=1
if [[ -x "${FRPS_DIR}/frps" ]]; then
  CURRENT_FRPS_VERSION="$(${FRPS_DIR}/frps --version 2>/dev/null || true)"
  if [[ "$CURRENT_FRPS_VERSION" == "$FRP_VERSION" ]]; then
    NEED_INSTALL_FRPS=0
    log "检测到 frps ${FRP_VERSION}，跳过下载"
  else
    warn "检测到已有 frps 版本 ${CURRENT_FRPS_VERSION:-未知}，将替换为 ${FRP_VERSION}"
  fi
fi

if [[ "$NEED_INSTALL_FRPS" == "1" ]]; then
  log "下载 frps ${FRP_VERSION} (${FRP_ARCH}) …"
  TARBALL="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TARBALL}"
  TMPD="$(mktemp -d)"
  curl -fsSL -# "$URL" -o "${TMPD}/${TARBALL}"
  tar xzf "${TMPD}/${TARBALL}" -C "$TMPD"
  cp "${TMPD}/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" "${FRPS_DIR}/frps"
  rm -rf "$TMPD"
  chmod +x "${FRPS_DIR}/frps"
  log "frps 安装完成：$(${FRPS_DIR}/frps --version 2>/dev/null | sed 's/^/frps /')"
fi

# ── 生成配置 ────────────────────────────────────────────────

# 从面板地址提取域名用于 httpPlugins
PANEL_HOST="${PANEL_URL#https://}"
PANEL_HOST="${PANEL_HOST#http://}"
NODE_TOKEN_QUERY="$(url_encode "${FRPS_TOKEN}")"

cat > "${FRPS_DIR}/frps.toml" << EOF
# ───────────────────────────────────
# frp-manager-lite frps 节点：${NODE_NAME}
# 地区：${REGION}
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
# frp ${FRP_VERSION}
# ───────────────────────────────────

bindAddr = "0.0.0.0"
bindPort = ${FRPS_BIND_PORT}
kcpBindPort = ${FRPS_BIND_PORT}

auth.method = "token"
auth.token = "${FRPS_TOKEN}"

# frp 0.66+ 传输层优化
transport.tcpMux = true
transport.maxPoolCount = 5

# 回调面板验权：带上节点身份，面板会校验账号、节点和端口归属。
[[httpPlugins]]
name = "frp-manager-lite-auth"
addr = "${PANEL_HOST}"
path = "/frp-plugin?node_id=${NODE_ID}&node_token=${NODE_TOKEN_QUERY}"
ops = ["Login", "NewProxy"]

# 仪表盘（仅建议内网访问）
webServer.addr = "0.0.0.0"
webServer.port = ${FRPS_DASHBOARD_PORT}
webServer.user = "${FRPS_DASHBOARD_USER}"
webServer.password = "${FRPS_DASHBOARD_PWD}"

# Prometheus 监控指标
EOF

log "配置文件已生成：${FRPS_DIR}/frps.toml"

# ── systemd 服务 ────────────────────────────────────────────

SERVICE_NAME="frps-${NODE_NAME}"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=frps node ${NODE_NAME} (${REGION}) for frp-manager-lite
After=network.target

[Service]
Type=simple
ExecStart=${FRPS_DIR}/frps -c ${FRPS_DIR}/frps.toml
Restart=always
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

# ── 等待启动 ────────────────────────────────────────────────

echo ''
log "等待 frps 启动…"
sleep 2
for _ in $(seq 1 10); do
  if ss -tlnp 2>/dev/null | grep -q ":${FRPS_BIND_PORT}" || netstat -tlnp 2>/dev/null | grep -q ":${FRPS_BIND_PORT}"; then
    break
  fi
  sleep 1
done

if ss -tlnp 2>/dev/null | grep -q ":${FRPS_BIND_PORT}" || netstat -tlnp 2>/dev/null | grep -q ":${FRPS_BIND_PORT}"; then
  log "frps 已启动 ✅"
else
  warn "frps 可能未成功启动，检查日志：journalctl -u ${SERVICE_NAME} -n 30"
fi

# ── 端口限速同步 ────────────────────────────────────────────

install_rate_limit_sync() {
  if [[ "${ENABLE_PORT_RATE_LIMIT:-1}" != "1" ]]; then
    warn "已跳过端口限速同步安装（ENABLE_PORT_RATE_LIMIT=0）"
    return 0
  fi
  if [[ -z "${NODE_ID:-}" ]]; then
    warn "节点 ID 为空，跳过端口限速同步安装"
    return 0
  fi
  command -v tc >/dev/null 2>&1 || { warn "缺少 tc(iproute2)，跳过端口限速同步"; return 0; }
  command -v iptables >/dev/null 2>&1 || { warn "缺少 iptables，跳过端口限速同步"; return 0; }

  cat > "${FRPS_DIR}/rate-limit.env" <<EOF
PANEL_URL=${PANEL_URL}
FML_SETUP_KEY=${SETUP_KEY}
FML_RATE_LIMIT_NODE_ID=${NODE_ID}
FML_RATE_LIMIT_IFACE=${FML_RATE_LIMIT_IFACE:-}
EOF
  chmod 600 "${FRPS_DIR}/rate-limit.env"

  cat > /usr/local/sbin/fml-sync-port-rate-limits <<'SYNC_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE="${ENV_FILE:-}"
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
load_env(){ if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi; }
detect_iface(){ if [[ -n "$IFACE" ]]; then return 0; fi; IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"; [[ -n "$IFACE" ]] || IFACE="$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"; [[ -n "$IFACE" ]] || { err "无法自动识别出口网卡，请设置 FML_RATE_LIMIT_IFACE=eth0"; exit 1; }; }
api_url(){ local url="${PANEL_URL%/}/api/host/port-rate-rules"; if [[ -n "$NODE_ID" ]]; then url="${url}?node_id=${NODE_ID}"; fi; printf '%s' "$url"; }
fetch_rules(){ local url tmp; url="$(api_url)"; tmp="$(mktemp)"; if ! curl -fsS --connect-timeout 5 --max-time 20 -H "X-FML-Setup-Key: ${FML_SETUP_KEY}" "$url" -o "$tmp"; then rm -f "$tmp"; err "拉取限速规则失败：$url"; exit 1; fi; python3 - "$tmp" <<'PY'
import json, sys
path=sys.argv[1]
data=json.load(open(path,'r',encoding='utf-8'))
if not data.get('ok'): raise SystemExit(data.get('error') or 'API returned ok=false')
for r in data.get('rules') or []:
    port=int(r.get('port') or 0); proto=str(r.get('protocol') or 'tcp').lower(); rate=int(r.get('rate_kbit') or 0)
    if port>0 and proto in {'tcp','udp'} and rate>0: print(f'{port}\t{proto}\t{rate}')
PY
rm -f "$tmp"; }
clear_rules(){ run iptables -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null || true; run iptables -t mangle -F "$CHAIN" 2>/dev/null || true; run iptables -t mangle -X "$CHAIN" 2>/dev/null || true; if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "qdisc htb ${QDISC_HANDLE}:"; then run tc qdisc del dev "$IFACE" root 2>/dev/null || true; fi; }
guard_existing_qdisc(){ local line; line="$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$0 ~ / root / {print; exit}')"; [[ -z "$line" ]] && return 0; if grep -q "qdisc htb ${QDISC_HANDLE}:" <<< "$line"; then return 0; fi; if [[ "$FORCE" == "1" ]]; then warn "将覆盖现有 root qdisc：$line"; return 0; fi; if grep -Eq 'qdisc (fq_codel|pfifo_fast|noqueue|mq) ' <<< "$line"; then warn "将替换系统默认 root qdisc：$line"; return 0; fi; err "检测到已有自定义 root qdisc，默认不覆盖：$line；如确认可覆盖，设置 FML_RATE_LIMIT_FORCE=1"; exit 1; }
ensure_base(){ guard_existing_qdisc; modprobe sch_htb 2>/dev/null || true; modprobe cls_fw 2>/dev/null || true; run iptables -t mangle -N "$CHAIN" 2>/dev/null || true; run iptables -t mangle -F "$CHAIN"; if ! iptables -t mangle -C OUTPUT -j "$CHAIN" >/dev/null 2>&1; then run iptables -t mangle -A OUTPUT -j "$CHAIN"; fi; run tc qdisc replace dev "$IFACE" root handle "${QDISC_HANDLE}:" htb default "$DEFAULT_CLASS"; run tc class replace dev "$IFACE" parent "${QDISC_HANDLE}:" classid "${QDISC_HANDLE}:${DEFAULT_CLASS}" htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE"; }
apply_rules(){ local rules count=0 idx=1; rules="$(fetch_rules)"; if [[ -z "$rules" ]]; then clear_rules; log "没有需要应用的端口速率策略；已清空 ${CHAIN} 规则。"; return 0; fi; ensure_base; while IFS=$'\t' read -r port proto rate_kbit; do [[ -n "$port" ]] || continue; local mark classid; mark=$((MARK_BASE+idx)); classid=$((CLASS_BASE+idx)); run tc class replace dev "$IFACE" parent "${QDISC_HANDLE}:" classid "${QDISC_HANDLE}:${classid}" htb rate "${rate_kbit}kbit" ceil "${rate_kbit}kbit"; run tc filter replace dev "$IFACE" protocol ip parent "${QDISC_HANDLE}:" prio 10 handle "$mark" fw flowid "${QDISC_HANDLE}:${classid}"; if [[ "$proto" == "tcp" ]]; then run iptables -t mangle -A "$CHAIN" -p tcp --sport "$port" -j MARK --set-mark "$mark"; else run iptables -t mangle -A "$CHAIN" -p udp --sport "$port" -j MARK --set-mark "$mark"; fi; count=$((count+1)); idx=$((idx+1)); done <<< "$rules"; log "已应用 ${count} 条端口速率策略：iface=${IFACE}, node_id=${NODE_ID}"; }
main(){ [[ "$(id -u)" == "0" ]] || { err "请用 root 执行"; exit 1; }; need_cmd curl; need_cmd python3; need_cmd ip; need_cmd tc; need_cmd iptables; load_env; [[ -n "$PANEL_URL" ]] || { err "缺少 PANEL_URL"; exit 1; }; [[ -n "$FML_SETUP_KEY" ]] || { err "缺少 FML_SETUP_KEY"; exit 1; }; detect_iface; if [[ "$CLEAR" == "1" ]]; then clear_rules; log "已清理端口速率策略"; return 0; fi; apply_rules; }
main "$@"
SYNC_SCRIPT
  chmod 0755 /usr/local/sbin/fml-sync-port-rate-limits

  cat > "/etc/systemd/system/fml-port-rate-limit-${NODE_NAME}.service" <<EOF
[Unit]
Description=Sync frp-manager-lite port rate limits for node ${NODE_NAME}
After=network-online.target ${SERVICE_NAME}.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=ENV_FILE=${FRPS_DIR}/rate-limit.env
EnvironmentFile=${FRPS_DIR}/rate-limit.env
ExecStart=/usr/local/sbin/fml-sync-port-rate-limits
EOF

  cat > "/etc/systemd/system/fml-port-rate-limit-${NODE_NAME}.timer" <<EOF
[Unit]
Description=Run frp-manager-lite port rate-limit sync for node ${NODE_NAME}

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=fml-port-rate-limit-${NODE_NAME}.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "fml-port-rate-limit-${NODE_NAME}.timer"
  systemctl start "fml-port-rate-limit-${NODE_NAME}.service" || warn "端口限速首次同步失败，可查看：journalctl -u fml-port-rate-limit-${NODE_NAME}.service -n 80"
  log "端口限速同步已启用：fml-port-rate-limit-${NODE_NAME}.timer"
}

install_rate_limit_sync

# ── 完成 ────────────────────────────────────────────────────

echo ''
echo -e "${GREEN}  ╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║   🎉 节点 ${NODE_NAME} 添加完成！  ║${NC}"
echo -e "${GREEN}  ╚══════════════════════════════════════╝${NC}"
echo ''
echo "  节点名称：    ${NODE_NAME}"
echo "  地区：        ${REGION}"
echo "  公网 IP：     ${SERVER_IP}"
echo "  frps 端口：   ${FRPS_BIND_PORT}"
echo "  端口池：      ${PORT_START} - ${PORT_END}（${PORT_COUNT} 个）"
echo "  仪表盘：      ${DASHBOARD_URL}"
echo "  仪表盘用户：  ${FRPS_DASHBOARD_USER}"
echo "  仪表盘密码：  ${FRPS_DASHBOARD_PWD}"
echo ''
echo -e "${YELLOW}  ⚠️  防火墙提醒：请放行以下端口${NC}"
echo "     TCP ${FRPS_BIND_PORT}  — frps 通信"
echo "     TCP ${PORT_START}-${PORT_END}  — 用户隧道"
echo "     TCP ${FRPS_DASHBOARD_PORT}  — 仪表盘（建议仅内网）"
echo ''
echo "  管理命令："
echo "    systemctl start ${SERVICE_NAME}    启动"
echo "    systemctl stop ${SERVICE_NAME}     停止"
echo "    systemctl restart ${SERVICE_NAME}  重启"
echo "    systemctl status ${SERVICE_NAME}   状态"
echo "    journalctl -u ${SERVICE_NAME} -f   日志"
echo "    systemctl status fml-port-rate-limit-${NODE_NAME}.timer  端口限速同步"
echo "    DRY_RUN=1 ENV_FILE=${FRPS_DIR}/rate-limit.env /usr/local/sbin/fml-sync-port-rate-limits  限速预览"
echo ''
