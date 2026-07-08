#!/bin/bash

# 1. 确保安装必要的依赖
apt-get update -y
apt-get install -y wget curl openssl python3

# 2. 下载并安装 cloudflared (自动适配架构)
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

# 3. 生成偷苹果官网 SNI 的自签证书 (www.apple.com)
echo "正在生成苹果官网 (www.apple.com) 的自签证书..."
openssl ecparam -genkey -name prime256v1 -out apple_private.key 2>/dev/null
openssl req -new -x509 -days 36500 -key apple_private.key -out apple_cert.crt -subj "/C=US/ST=California/L=Cupertino/O=Apple Inc./CN=www.apple.com" 2>/dev/null

# 4. 定义死变量（优选域名和SNI）
PREFERRED_DOMAIN="5cm.cf.090227.xyz"
SNI="www.apple.com"

# 5. 交互输入节点必要信息
echo "请输入后端的 VLESS UUID (直接回车则自动随机生成):"
read -r UUID
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "已自动生成 UUID: $UUID"
fi

echo "请输入后端的 WebSocket 路径 (例如 /vless，直接回车默认为 /):"
read -r WS_PATH
if [ -z "$WS_PATH" ]; then
    WS_PATH="/"
fi

echo "请输入 Cloudflare Token (直接回车则使用临时隧道):"
read -r CF_TOKEN

# 6. 判断并启动 Argo 隧道
if [ -z "$CF_TOKEN" ]; then
    echo "未输入 Token，正在启动临时隧道..."
    # 默认将本地 8080 端口映射出去
    nohup cloudflared tunnel --url http://localhost:8080 > argo_temp.log 2>&1 &
    sleep 6
    # 提取生成的临时域名作为 Host
    ARGO_DOMAIN=$(grep -o 'https://[-0-9a-z]*\.trycloudflare\.com' argo_temp.log | sed 's/https:\/\///' | head -n 1)
    if [ -z "$ARGO_DOMAIN" ]; then
        echo "临时隧道域名获取失败，请检查 argo_temp.log"
        exit 1
    fi
    REMARK="Argo临时节点"
else
    echo "检测到 Token，正在配置并启动固定隧道..."
    echo "请输入你在 Cloudflare Zero Trust 为该隧道绑定的公网域名 (用于 Host，例如 argo.yourdomain.com):"
    read -r ARGO_DOMAIN
    if [ -z "$ARGO_DOMAIN" ]; then
        echo "固定隧道必须输入绑定的域名才能生成正确的节点链接！"
        exit 1
    fi
    cloudflared service install "$CF_TOKEN"
    systemctl start cloudflared
    systemctl enable cloudflared
    echo "固定隧道已作为系统服务启动并在后台运行。"
    REMARK="Argo固定节点"
fi

# 7. 对 Path 进行 URL 编码 (解决带有 ? 等特殊字符的问题)
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$WS_PATH'''))" 2>/dev/null || echo "${WS_PATH//\//%2F}")

# 8. 打印最终的 VLESS 链接
VLESS_LINK="vless://${UUID}@${PREFERRED_DOMAIN}:443?encryption=none&security=tls&sni=${SNI}&fp=chrome&alpn=http%2F1.1&insecure=0&allowInsecure=0&type=ws&host=${ARGO_DOMAIN}&path=${ENCODED_PATH}#${REMARK}"

echo ""
echo "================================================="
echo "Argo 隧道及 VLESS 节点链接生成完毕："
echo ""
echo "$VLESS_LINK"
echo ""
echo "================================================="
