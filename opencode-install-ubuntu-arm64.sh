#!/usr/bin/env bash
#
# OpenCode 一键安装启动脚本 (Ubuntu / ARM64 / aarch64)
# 功能: 更新系统 -> 安装 opencode -> 为本机 IP 生成临时 HTTPS 证书 -> 启动 Web 界面
#       -> 输出访问地址 / 账号 / 密码 (账号密码同时保存在 /root/opencode_credentials.txt)
#
# 用法: sudo bash opencode-install-ubuntu-arm64.sh
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
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  err "本脚本面向 Ubuntu ARM64 (aarch64)，当前架构为 '$ARCH'。"
  exit 1
fi

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
echo -e "${C_B}========== OpenCode 一键安装启动器 (ARM64) ==========${C_NC}"
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
      "https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-arm64.tar.gz"
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
IP="$(ip -4 route get 1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1)"
[ -z "$IP" ] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$IP" ] && IP="127.0.0.1"
ok "本机 IP: $IP"

mkdir -p /etc/opencode
openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
  -keyout /etc/opencode/opencode.key \
  -out /etc/opencode/opencode.crt \
  -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" >/dev/null 2>&1
chmod 600 /etc/opencode/opencode.key
ok "临时证书已生成 (自签名, 有效期 90 天): /etc/opencode/"

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
cat > "$CRED_FILE" <<EOF
OpenCode Web 访问信息
=====================
访问地址: https://$IP:$HTTPS_PORT
用户名:   $USERNAME
密码:     $PASSWORD

说明: 证书为临时自签名证书(有效期90天)，浏览器首次会提示“不安全”，属正常现象，请手动继续访问。
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

    ssl_certificate     /etc/opencode/opencode.crt;
    ssl_certificate_key /etc/opencode/opencode.key;
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
sed -i "s/__HTTPS_PORT__/$HTTPS_PORT/g; s/__SERVER_NAME__/$IP/g; s/__OC_PORT__/$OC_PORT/g" \
  /etc/nginx/sites-available/opencode.conf
ln -sf /etc/nginx/sites-available/opencode.conf /etc/nginx/sites-enabled/opencode.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
ok "nginx 反向代理配置完成"

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
warn "当前证书为临时自签名证书 (有效 90 天, 位于 /etc/opencode/)，浏览器会提示不安全属正常现象。"
warn "如需受信任证书: 公网 CA 不对 IP 发放证书，请绑定域名后通过 certbot 申请；"
warn "或向支持 IP 证书的 CA (如阿里云/腾讯云等) 单独申请后替换 /etc/opencode/ 下证书并重启 nginx。"
echo -e "${C_YEL}提示: 首次使用还需登录/配置 LLM 提供商的 API Key 才能对话。${C_NC}"
echo