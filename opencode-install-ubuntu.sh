#!/usr/bin/env bash
#
# OpenCode 一键安装启动脚本 (Ubuntu / Debian，支持 ARM64/aarch64 与 x86_64/amd64)
# 功能: 更新系统 -> 安装 opencode -> 为本机 IP 生成/申请 HTTPS 证书 -> 启动 Web 界面
#       -> 输出访问地址 / 账号 / 密码 (账号密码同时保存在 /root/opencode_credentials.txt)
#
# 用法: sudo bash opencode-install-ubuntu.sh
#
set -euo pipefail

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YEL='\033[1;33m'
C_CYN='\033[0;36m'; C_B='\033[1;36m'; C_NC='\033[0m'

info() { echo -e "${C_CYN}[INFO]${C_NC} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_NC} $*"; }
warn() { echo -e "${C_YEL}[WARN]${C_NC} $*"; }
err()  { echo -e "${C_RED}[ERR ]${C_NC} $*" >&2; }

# ---------------------------------------------------------------- 平台校验
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64)
    OC_ASSET_ARCH="arm64"
    ;;
  x86_64|amd64)
    OC_ASSET_ARCH="x64"
    ;;
  *)
    err "本脚本仅支持 ARM64(aarch64) 与 x86_64(amd64)，当前架构为 '$ARCH'。"
    exit 1
    ;;
esac

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  err "无法识别操作系统。"
  exit 1
fi
if [ "${ID:-}" != "ubuntu" ] && [ "${ID:-}" != "debian" ] && [ "${ID:-}" != "raspbian" ]; then
  err "仅支持 Ubuntu/Debian 系系统，当前系统: ${PRETTY_NAME:-unknown}。"
  exit 1
fi

# ---------------------------------------------------------------- 提权到 root
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    warn "需要 root 权限，正在通过 sudo 重新执行本脚本..."
    exec sudo -H bash "$0" "$@"
  else
    err "请使用 root 或 sudo 运行本脚本。"
    exit 1
  fi
fi
export HOME=/root
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo
echo -e "${C_B}========== OpenCode 一键安装启动器 ($ARCH) ==========${C_NC}"
echo

# ---------------------------------------------------------------- 1. 更新系统
info "1/6 更新系统软件包 (apt update && apt upgrade) ..."
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::=--force-confnew
ok "系统软件包更新完成"

# ---------------------------------------------------------------- 2. 安装依赖
info "2/6 安装依赖 (curl / openssl / nginx) ..."
apt-get install -y curl ca-certificates openssl nginx
ok "依赖安装完成"

# ---------------------------------------------------------------- 3. 安装 opencode
info "3/6 安装 opencode ..."
INSTALL_DIR="$HOME/.opencode/bin"
if command -v opencode >/dev/null 2>&1; then
  ok "opencode 已存在: $(command -v opencode)"
else
  if curl -fsSL https://opencode.ai/install | bash; then
    ok "通过官方脚本安装 opencode 成功"
  else
    warn "官方脚本安装失败，尝试从 GitHub Release 直接下载 ..."
    curl -fsSL -o /tmp/opencode.tar.gz \
      "https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-${OC_ASSET_ARCH}.tar.gz"
    mkdir -p "$INSTALL_DIR" /tmp/ocinst
    tar -xzf /tmp/opencode.tar.gz -C /tmp/ocinst
    install -m 0755 /tmp/ocinst/opencode "$INSTALL_DIR/opencode"
    rm -rf /tmp/ocinst /tmp/opencode.tar.gz
    ok "通过 GitHub Release 安装 opencode 成功"
  fi
fi
export PATH="$INSTALL_DIR:$PATH"
hash -r 2>/dev/null || true
if ! command -v opencode >/dev/null 2>&1; then
  err "opencode 安装失败，请检查网络后重试。"
  exit 1
fi
OC_BIN="$(command -v opencode)"
OC_BINDIR="$(dirname "$OC_BIN")"
ok "opencode 已就绪: $OC_BIN  (version: $(opencode --version 2>/dev/null | head -n1))"

# ---------------------------------------------------------------- 4. 获取 IP 并生成临时证书
info "4/6 检测本机 IP 并生成临时 HTTPS 证书 ..."

# 内网 IP (用于本机绑定/内网访问)
PRIV_IP="$(ip -4 route get 1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1)"
[ -z "$PRIV_IP" ] && PRIV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$PRIV_IP" ] && PRIV_IP="127.0.0.1"

# 公网 IP (甲骨文云等 NAT 架构下, 网卡上看不到公网 IP, 需要向外部服务查询)
PUB_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip" "https://ipv4.icanhazip.com"; do
  PUB_IP="$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d ' \n\r')"
  # 简单校验是否是合法 IPv4
  if echo "$PUB_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    break
  else
    PUB_IP=""
  fi
done

if [ -n "$PUB_IP" ] && [ "$PUB_IP" != "$PRIV_IP" ]; then
  IP="$PUB_IP"
  ok "内网 IP: $PRIV_IP  |  公网 IP: $PUB_IP (对外访问请使用公网 IP)"
else
  IP="$PRIV_IP"
  if [ -z "$PUB_IP" ]; then
    warn "未能获取到公网 IP (可能是出站网络受限), 将使用内网 IP: $IP"
    warn "如果你是甲骨文云等 NAT 架构, 请确认安全列表/子网路由已放行, 或手动用公网 IP 访问并在浏览器中忽略证书告警。"
  fi
fi

mkdir -p /etc/opencode

# ---- 尝试申请 Let's Encrypt 受信任的 IP 证书 (2026年起支持, 有效期约6天/160小时, 需自动续期) ----
# 前提: PUB_IP 必须是真实公网 IP, 且服务器 80 端口能被公网访问 (用于 http-01 校验)
USE_TRUSTED_CERT=false
CERT_FILE=""
KEY_FILE=""
CERTBOT_BIN=""

if [ -n "$PUB_IP" ] && [ "$PUB_IP" != "$PRIV_IP" ]; then
  info "尝试为公网 IP $PUB_IP 申请 Let's Encrypt 受信任证书 (IP 证书, 有效期约 6 天, 会自动续期) ..."

  apt-get install -y certbot >/dev/null 2>&1 || true
  CERTBOT_BIN="$(command -v certbot || true)"

  # IP 证书需要 certbot >= 5.4 (支持 --ip-address), apt 版本太老则尝试用 pip 升级
  need_upgrade=false
  if [ -n "$CERTBOT_BIN" ]; then
    ver="$(certbot --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
    major="${ver%%.*}"; minor="${ver##*.}"
    if [ -z "$ver" ] || [ "$major" -lt 5 ] 2>/dev/null || { [ "$major" -eq 5 ] 2>/dev/null && [ "$minor" -lt 4 ] 2>/dev/null; }; then
      need_upgrade=true
    fi
  else
    need_upgrade=true
  fi
  if [ "$need_upgrade" = true ]; then
    warn "certbot 版本过低或未安装 (IP 证书需要 >=5.4), 尝试通过 pip 升级/安装 ..."
    apt-get install -y python3-pip >/dev/null 2>&1 || true
    pip3 install --upgrade certbot >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true
    CERTBOT_BIN="$(command -v certbot || true)"
  fi

  # 放行 80 端口 (http-01 校验必须走 80), 甲骨文云还需在控制台安全列表里放行, 脚本无法代劳
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "^Status: active"; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
  fi

  if [ -n "$CERTBOT_BIN" ]; then
    systemctl stop nginx >/dev/null 2>&1 || true
    if "$CERTBOT_BIN" certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        --preferred-profile shortlived \
        --ip-address "$PUB_IP" >/tmp/certbot-opencode.log 2>&1; then
      LE_DIR="/etc/letsencrypt/live/$PUB_IP"
      if [ -f "$LE_DIR/fullchain.pem" ] && [ -f "$LE_DIR/privkey.pem" ]; then
        CERT_FILE="$LE_DIR/fullchain.pem"
        KEY_FILE="$LE_DIR/privkey.pem"
        USE_TRUSTED_CERT=true
        ok "Let's Encrypt IP 证书申请成功 (浏览器将直接信任, 有效期约 6 天, 已配置自动续期)"
      fi
    else
      warn "Let's Encrypt IP 证书申请失败 (常见原因: 公网 80 端口未在甲骨文云安全列表放行), 详情见 /tmp/certbot-opencode.log"
      warn "将回退为自签名证书。"
    fi
    systemctl start nginx >/dev/null 2>&1 || true
  else
    warn "certbot 不可用, 跳过受信任证书申请, 将使用自签名证书。"
  fi
fi

# ---- 回退方案: 本地自签名证书 (无需公网/80端口, 但浏览器会提示不安全) ----
if [ "$USE_TRUSTED_CERT" != true ]; then
  SAN="subjectAltName=IP:$PRIV_IP"
  [ -n "$PUB_IP" ] && [ "$PUB_IP" != "$PRIV_IP" ] && SAN="subjectAltName=IP:$PUB_IP,IP:$PRIV_IP"
  openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
    -keyout /etc/opencode/opencode.key \
    -out /etc/opencode/opencode.crt \
    -subj "/CN=$IP" -addext "$SAN" >/dev/null 2>&1
  chmod 600 /etc/opencode/opencode.key
  CERT_FILE="/etc/opencode/opencode.crt"
  KEY_FILE="/etc/opencode/opencode.key"
  ok "临时证书已生成 (自签名, 有效期 90 天): /etc/opencode/"
fi

# ---------------------------------------------------------------- 分配端口
find_free_port() {
  local p="$1"
  while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$"; do
    p=$((p + 1))
  done
  echo "$p"
}
OC_PORT="$(find_free_port 4096)"
HTTPS_PORT="$(find_free_port 443)"

# ---------------------------------------------------------------- 账号密码
USERNAME="opencode"
PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 16)"
CRED_FILE=/root/opencode_credentials.txt
if [ "$USE_TRUSTED_CERT" = true ]; then
  CERT_NOTE="证书为 Let's Encrypt 受信任的 IP 证书, 浏览器不会提示不安全。注意: 该证书有效期约 6 天, 已配置自动续期 (systemd timer), 无需手动处理。"
else
  CERT_NOTE="证书为临时自签名证书(有效期90天)，浏览器首次会提示“不安全”，属正常现象，请手动继续访问。"
fi
cat > "$CRED_FILE" <<EOF
OpenCode Web 访问信息
=====================
访问地址: https://$IP:$HTTPS_PORT
用户名:   $USERNAME
密码:     $PASSWORD

说明: $CERT_NOTE
EOF
chmod 600 "$CRED_FILE"
ok "账号密码已保存: $CRED_FILE"

cat > /etc/opencode/opencode.env <<EOF
OPENCODE_SERVER_USERNAME=$USERNAME
OPENCODE_SERVER_PASSWORD=$PASSWORD
EOF
chmod 600 /etc/opencode/opencode.env

# ---------------------------------------------------------------- 5. nginx 反向代理 (HTTPS)
info "5/6 配置 nginx HTTPS 反向代理(端口 $HTTPS_PORT) -> opencode(端口 $OC_PORT) ..."
cat > /etc/nginx/sites-available/opencode.conf <<'NGINXEOF'
server {
    listen __HTTPS_PORT__ ssl;
    listen [::]:__HTTPS_PORT__ ssl;
    server_name __SERVER_NAME__;

    ssl_certificate     __CERT_FILE__;
    ssl_certificate_key __KEY_FILE__;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:__OC_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINXEOF
sed -i "s/__HTTPS_PORT__/$HTTPS_PORT/g; s/__SERVER_NAME__/$IP/g; s/__OC_PORT__/$OC_PORT/g; \
  s#__CERT_FILE__#$CERT_FILE#g; s#__KEY_FILE__#$KEY_FILE#g" \
  /etc/nginx/sites-available/opencode.conf
ln -sf /etc/nginx/sites-available/opencode.conf /etc/nginx/sites-enabled/opencode.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
ok "nginx 反向代理配置完成"

# 若使用了 Let's Encrypt IP 证书 (仅6天有效期), 配置自动续期 + 续期后自动 reload nginx
if [ "$USE_TRUSTED_CERT" = true ] && [ -n "$CERTBOT_BIN" ]; then
  cat > /etc/systemd/system/opencode-cert-renew.service <<EOF
[Unit]
Description=Renew opencode IP TLS certificate (Let's Encrypt)

[Service]
Type=oneshot
ExecStart=$CERTBOT_BIN renew --quiet --deploy-hook "systemctl reload nginx"
EOF
  cat > /etc/systemd/system/opencode-cert-renew.timer <<'EOF'
[Unit]
Description=Twice-daily check for opencode IP certificate renewal

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now opencode-cert-renew.timer >/dev/null 2>&1
  ok "证书自动续期已配置 (每天两次检查, 到期前自动续期并重载 nginx)"
fi

# ---------------------------------------------------------------- 6. opencode 后台服务
info "6/6 配置并启动 opencode web 服务 ..."
cat > /etc/systemd/system/opencode.service <<EOF
[Unit]
Description=opencode web server
After=network.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/opencode/opencode.env
Environment=HOME=/root
Environment=PATH=$OC_BINDIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=/root
ExecStart=$OC_BIN web --port $OC_PORT --hostname 127.0.0.1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable opencode >/dev/null 2>&1
systemctl restart opencode

# ---------------------------------------------------------------- 防火墙放行
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "^Status: active"; then
  ufw allow "$HTTPS_PORT/tcp" >/dev/null 2>&1 || true
  ok "防火墙 (ufw) 已放行端口 $HTTPS_PORT/tcp"
fi

# ---------------------------------------------------------------- 结果检查
sleep 3
if systemctl is-active --quiet opencode; then
  ok "opencode web 服务运行中"
else
  warn "opencode 服务未正常启动，请查看日志: journalctl -u opencode -e"
fi
HTTP_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' \
  "https://127.0.0.1:$HTTPS_PORT/" 2>/dev/null || echo 000)"

echo
echo -e "${C_B}======================= 部署完成 =======================${C_NC}"
echo -e "  ${C_GREEN}访问地址:${C_NC}   https://$IP:$HTTPS_PORT"
echo -e "  ${C_GREEN}用户名:${C_NC}     $USERNAME"
echo -e "  ${C_GREEN}密码:${C_NC}       $PASSWORD"
echo
echo -e "  账号密码已保存至: ${C_YEL}$CRED_FILE${C_NC}"
echo -e "   HTTPS 探活结果:  ${HTTP_CODE}"
echo -e "   日志查看:        journalctl -u opencode -f"
echo -e "   停止/启动:       systemctl stop opencode  /  systemctl start opencode"
echo -e "   常用操作:        sudo bash $0   (初始化完成后再次运行可重启服务)"
echo
if [ "$USE_TRUSTED_CERT" = true ]; then
  ok "当前证书为 Let's Encrypt 受信任 IP 证书 (CN/SAN=$PUB_IP)，浏览器不会提示不安全。"
  ok "证书有效期约 6 天，已通过 systemd timer (opencode-cert-renew.timer) 每日两次自动检查续期，无需手动处理。"
  warn "续期依赖 80 端口可被公网访问 (http-01 校验)，请确保甲骨文云安全列表长期放行 80 端口，否则续期会失败并在 90 天自签名证书生成前需要人工介入。"
else
  warn "当前证书为临时自签名证书 (有效 90 天, 位于 /etc/opencode/)，浏览器会提示不安全属正常现象。"
  if [ -f /tmp/certbot-opencode.log ]; then
    warn "本机曾尝试为公网 IP $PUB_IP 申请 Let's Encrypt 受信任证书但未成功 (常见原因: 80 端口未在甲骨文云安全列表放行)，详情见 /tmp/certbot-opencode.log。"
    warn "在安全列表放行 80 端口后重新运行本脚本，即可再次尝试申请受信任证书。"
  else
    warn "未获取到公网 IP，因此未尝试申请受信任证书。若确认本机有公网 IP 但获取失败，可检查出站网络是否能访问 ifconfig.me 等服务。"
  fi
fi
echo -e "${C_YEL}提示: 首次使用还需登录/配置 LLM 提供商的 API Key 才能对话。${C_NC}"
echo