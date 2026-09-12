# opencode-ubuntu-arm64-installer

OpenCode 一键安装启动脚本（Ubuntu / ARM64，如甲骨文 Arm / AWS Graviton / 树莓派）。

## 功能

- 自动 `apt update && apt upgrade`
- 安装 opencode（官方脚本，失败时自动从 GitHub Release 下载 linux-arm64 包）
- 以本机 IP 生成临时 HTTPS 证书（自签名，90 天）
- 配置 nginx 反向代理（支持 WebSocket / SSE）
- 注册为 systemd 服务（崩溃自动重启）
- 自动放行防火墙端口（ufw）
- 启动后输出访问地址、用户名、密码，并保存到 `/root/opencode_credentials.txt`

## 使用方法

在 ARM64 的 Ubuntu / Debian 服务器上，任选一种方式：

### 方式一：直接下载执行（推荐）

```bash
curl -fsSL -o opencode-install.sh https://raw.githubusercontent.com/WhyVPS/opencode-ubuntu-arm64-installer/main/opencode-install-ubuntu-arm64.sh
sudo bash opencode-install.sh
```

如服务器上无 `curl`，可用 `wget`：

```bash
wget -O opencode-install.sh https://raw.githubusercontent.com/WhyVPS/opencode-ubuntu-arm64-installer/main/opencode-install-ubuntu-arm64.sh
sudo bash opencode-install.sh
```

### 方式二：克隆仓库后执行

```bash
git clone https://github.com/WhyVPS/opencode-ubuntu-arm64-installer.git
cd opencode-ubuntu-arm64-installer
sudo bash opencode-install-ubuntu-arm64.sh
```

### 访问

脚本运行完成后，用浏览器访问打印出的地址：

```
https://<服务器IP>:443
```

> 证书为临时自签名证书，浏览器提示“不安全”属正常现象，点继续即可。
> 后端使用账号密码保护，用户名与密码保存在 `/root/opencode_credentials.txt`。

## 注意事项

- 仅支持 aarch64 (ARM64) 的 Ubuntu/Debian 系统
- 云服务器（如甲骨文）还需在云控制台的**安全列表**放行对应端口（默认 443）
- 公网 CA 不对纯 IP 发放证书；如需受信任证书，请绑定域名后用 certbot 申请，或购买支持 IP 证书的 CA 并替换 `/etc/opencode/` 下的证书
- 首次使用需在 Web 界面配置 LLM 提供商的 API Key

## 日志与维护

```bash
journalctl -u opencode -f   # 查看 opencode 日志
systemctl stop opencode     # 停止
systemctl start opencode    # 启动
```