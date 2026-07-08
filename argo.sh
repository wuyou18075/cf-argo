#!/bin/bash

# ==========================================
# 1. 检测并确保必要的依赖
# ==========================================
echo "正在检测基础依赖 (wget, curl, python3, openssl)..."
NEED_INSTALL=0
command -v wget >/dev/null 2>&1 || NEED_INSTALL=1
command -v curl >/dev/null 2>&1 || NEED_INSTALL=1
command -v python3 >/dev/null 2>&1 || NEED_INSTALL=1
command -v openssl >/dev/null 2>&1 || NEED_INSTALL=1

if [ "$NEED_INSTALL" -eq 1 ]; then
    echo "发现缺失依赖，正在自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y wget curl python3 openssl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wget curl python3 openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wget curl python3 openssl
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add wget curl python3 openssl
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm wget curl python3 openssl
    else
        echo "未找到支持的包管理器，请手动安装后重试。"
        exit 1
    fi
fi

# ==========================================
# 2. 下载并安装 cloudflared
# ==========================================
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    wget -q -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64
elif [ "$ARCH" = "x86_64" ]; then
    wget -q -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
else
    echo "不支持的系统架构: $ARCH"
    exit 1
fi
chmod +x cloudflared
mv cloudflared /usr/local/bin/

# ==========================================
# 3. 交互输入节点与 API 鉴权信息
# ==========================================
PREFERRED_DOMAIN="5cm.cf.090227.xyz"

echo "请输入后端的 VLESS UUID (直接回车自动生成):"
read -r UUID
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "已自动生成: $UUID"
fi

echo "请输入后端的 WebSocket 路径 (回车默认为 /):"
read -r WS_PATH
if [ -z "$WS_PATH" ]; then
    WS_PATH="/"
fi

echo "请输入本地后端业务监听的端口 (回车随机分配 40000-60000):"
read -r LOCAL_PORT
if [ -z "$LOCAL_PORT" ]; then
    LOCAL_PORT=$((RANDOM % 20001 + 40000))
    echo "已自动分配: $LOCAL_PORT"
fi

echo "请输入你的 Cloudflare 高权限 API Token (或 Global API Key):"
read -r CF_API_TOKEN
if [ -z "$CF_API_TOKEN" ]; then
    echo "错误: 必须输入 API Token 才能进行全自动部署！"
    exit 1
fi

echo "请输入你要绑定的公网域名 (例如 argo.yourdomain.com):"
read -r ARGO_DOMAIN
if [ -z "$ARGO_DOMAIN" ]; then
    echo "错误: 必须输入绑定的域名！"
    exit 1
fi

# ==========================================
# 4. 全自动 API 交互核心逻辑
# ==========================================
echo "------------------------------------------------"
echo "开始通过 API 自动配置 Cloudflare 资源..."

# [API] 4.1 获取 Zone ID 和 Account ID
echo "[1/6] 正在获取账号及域名信息..."
ZONES_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json")

ZONE_INFO=$(echo "$ZONES_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    domain = '$ARGO_DOMAIN'
    for z in data.get('result', []):
        if domain == z['name'] or domain.endswith('.' + z['name']):
            print(z['id'] + ',' + z['account']['id'])
            sys.exit(0)
    print('NOT_FOUND')
except:
    print('ERROR')
")

if [ "$ZONE_INFO" == "ERROR" ] || [ "$ZONE_INFO" == "NOT_FOUND" ]; then
    echo "❌ 失败: 无法找到域名对应的 Zone。请检查 Token 权限或域名是否拼写错误。"
    exit 1
fi
ZONE_ID=$(echo "$ZONE_INFO" | cut -d',' -f1)
ACCOUNT_ID=$(echo "$ZONE_INFO" | cut -d',' -f2)

# [API] 4.2 创建全新的 Argo 隧道
echo "[2/6] 正在创建全新的 Argo 隧道..."
TUNNEL_NAME="auto-argo-$(date +%s)"
TUNNEL_SECRET=$(openssl rand -base64 32)
CREATE_PAYLOAD=$(python3 -c "import json; print(json.dumps({'name': '$TUNNEL_NAME', 'config_src': 'cloudflare', 'tunnel_secret': '$TUNNEL_SECRET'}))")

TUNNEL_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data "$CREATE_PAYLOAD")

TUNNEL_ID=$(echo "$TUNNEL_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('result', {}).get('id', ''))")
if [ -z "$TUNNEL_ID" ]; then
    echo "❌ 失败: 隧道创建失败。请检查 Token 是否具备 Zero Trust 读写权限。"
    exit 1
fi

# [API] 4.3 配置隧道的回源路由 (Ingress)
echo "[3/6] 正在配置隧道流量路由 (Ingress -> localhost:$LOCAL_PORT)..."
ROUTE_PAYLOAD=$(python3 -c "import json; print(json.dumps({'config': {'ingress': [{'hostname': '$ARGO_DOMAIN', 'service': 'http://localhost:$LOCAL_PORT'}, {'service': 'http_status:404'}]}}))")

curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data "$ROUTE_PAYLOAD" >/dev/null

# [API] 4.4 清理可能存在的旧 DNS 记录
echo "[4/6] 正在清理旧的 DNS 解析记录..."
EXISTING_DNS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=$ARGO_DOMAIN" -H "Authorization: Bearer $CF_API_TOKEN")
RECORD_ID=$(echo "$EXISTING_DNS" | python3 -c "import sys, json; data=json.load(sys.stdin).get('result', []); print(data[0]['id'] if data else '')")
if [ -n "$RECORD_ID" ]; then
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" -H "Authorization: Bearer $CF_API_TOKEN" >/dev/null
fi

# [API] 4.5 创建新的 DNS CNAME 解析
echo "[5/6] 正在自动绑定 CNAME 解析到边缘节点..."
DNS_PAYLOAD=$(python3 -c "import json; print(json.dumps({'type': 'CNAME', 'name': '$ARGO_DOMAIN', 'content': '${TUNNEL_ID}.cfargotunnel.com', 'proxied': True, 'comment': 'Auto-created by Argo Script'}))")

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data "$DNS_PAYLOAD" >/dev/null

# [API] 4.6 获取运行凭证 (Run Token)
echo "[6/6] 正在提取服务运行凭证..."
TOKEN_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json")
RUN_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('result', ''))")

# ==========================================
# 5. 启动服务与清理
# ==========================================
echo "------------------------------------------------"
echo "API 配置完毕，正在将隧道安装为后台系统服务..."
# 停止可能存在的旧服务
systemctl stop cloudflared 2>/dev/null
cloudflared service uninstall 2>/dev/null

# 安装并启动新服务
cloudflared service install "$RUN_TOKEN"
systemctl start cloudflared 2>/dev/null || /usr/local/bin/cloudflared service start

# ==========================================
# 6. 生成并打印最终链接
# ==========================================
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$WS_PATH'''))" 2>/dev/null || echo "${WS_PATH//\//%2F}")
VLESS_LINK="vless://${UUID}@${PREFERRED_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&alpn=http%2F1.1&insecure=0&allowInsecure=0&type=ws&host=${ARGO_DOMAIN}&path=${ENCODED_PATH}#Argo全自动节点"

echo ""
echo "================================================="
echo "✅ Argo 隧道全自动部署及绑定成功！"
echo ""
echo "后台隧道名: $TUNNEL_NAME"
echo "本地监听端口: $LOCAL_PORT"
echo "绑定的域名: $ARGO_DOMAIN"
echo ""
echo "🔥 VLESS 节点链接:"
echo "$VLESS_LINK"
echo "================================================="
