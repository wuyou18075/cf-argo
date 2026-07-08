#!/bin/bash

# 1. 确保安装必要的依赖 (全自动适配常见 Linux 包管理器)
echo "正在检测系统包管理器并安装基础依赖 (wget, curl, python3)..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y wget curl python3
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wget curl python3
elif command -v yum >/dev/null 2>&1; then
    yum install -y wget curl python3
elif command -v apk >/dev/null 2>&1; then
    apk update
    apk add wget curl python3
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm wget curl python3
else
    echo "未找到支持的包管理器 (apt-get/dnf/yum/apk/pacman)。"
    exit 1
fi

# 2. 下载并安装 cloudflared
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

# 3. 定义优选域名
PREFERRED_DOMAIN="5cm.cf.090227.xyz"

# 4. 交互输入节点必要信息
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

echo "请输入本地后端业务监听的端口 (直接回车则随机分配 40000-60000 之间的端口):"
read -r LOCAL_PORT
if [ -z "$LOCAL_PORT" ]; then
    LOCAL_PORT=$((RANDOM % 20001 + 40000))
    echo "已自动分配本地端口: $LOCAL_PORT"
fi

echo "请输入 Cloudflare Token (直接回车则使用临时隧道):"
read -r CF_TOKEN

# 5. 判断并启动 Argo 隧道
if [ -z "$CF_TOKEN" ]; then
    echo "未输入 Token，正在启动临时隧道..."
    nohup cloudflared tunnel --url http://localhost:"$LOCAL_PORT" > argo_temp.log 2>&1 &
    
    echo "正在向 Cloudflare 申请临时域名，请稍候..."
    ARGO_DOMAIN=""
    for i in {1..15}; do
        sleep 2
        ARGO_DOMAIN=$(grep -o 'https://[-0-9a-z]*\.trycloudflare\.com' argo_temp.log | sed 's/https:\/\///' | head -n 1)
        if [ -n "$ARGO_DOMAIN" ]; then
            echo "成功获取临时域名！"
            break
        fi
    done

    # ================= WARP 备选方案逻辑开始 =================
    if [ -z "$ARGO_DOMAIN" ]; then
        echo "================ 错误 ================"
        echo "临时域名获取失败 (通常是因为当前服务器 IP 被 CF 拦截)。"
        
        # 交互：是否使用 WARP
        read -r -p "是否套用 WARP 改变出站 IP 建立临时隧道？(y/n，回车默认 y): " USE_WARP
        USE_WARP=${USE_WARP:-y}
        
        if [[ "$USE_WARP" == "y" || "$USE_WARP" == "Y" ]]; then
            echo "正在自动安装 Cloudflare WARP 官方客户端..."
            
            # 适配系统安装 WARP
            if command -v apt-get >/dev/null 2>&1; then
                apt-get install -y gpg lsb-release
                curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
                echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list
                apt-get update && apt-get install -y cloudflare-warp
            elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
                PM="yum"
                if command -v dnf >/dev/null 2>&1; then PM="dnf"; fi
                curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo > /etc/yum.repos.d/cloudflare-warp.repo
                $PM install -y cloudflare-warp
            else
                echo "当前系统的包管理器暂不支持自动化安装官方 WARP，请手动配置后重试。"
                exit 1
            fi

            # 注册并启动 WARP 改变出站 IP
            echo "正在注册并启动 WARP 接管网络..."
            warp-cli --accept-tos registration new
            warp-cli --accept-tos connect
            echo "等待 5 秒让 WARP 网络连通..."
            sleep 5
            
            # 清理旧的进程，重新利用 WARP 的 IP 申请隧道
            echo "出站 IP 已切换！正在重新申请临时隧道..."
            pkill -f "cloudflared tunnel"
            > argo_temp.log
            nohup cloudflared tunnel --url http://localhost:"$LOCAL_PORT" > argo_temp.log 2>&1 &
            
            ARGO_DOMAIN=""
            for i in {1..15}; do
                sleep 2
                ARGO_DOMAIN=$(grep -o 'https://[-0-9a-z]*\.trycloudflare\.com' argo_temp.log | sed 's/https:\/\///' | head -n 1)
                if [ -n "$ARGO_DOMAIN" ]; then
                    echo "通过 WARP 成功获取到临时域名！"
                    break
                fi
            done
            
            # 如果套了 WARP 还是失败，断开 WARP 还原网络并退出
            if [ -z "$ARGO_DOMAIN" ]; then
                echo "================ 彻底失败 ================"
                echo "套用 WARP 后仍然获取失败。可能是 WARP 分配的 IP 同样被风控。"
                echo "正在断开 WARP 还原您的服务器网络环境..."
                warp-cli --accept-tos disconnect
                echo "建议：请使用固定隧道 (输入 Token)。"
                exit 1
            fi
        else
            echo "已取消套用 WARP，脚本退出。"
            exit 1
        fi
    fi
    # ================= WARP 备选方案逻辑结束 =================

    REMARK="Argo临时节点"
else
    echo "检测到 Token，正在配置并启动固定隧道..."
    echo "请输入你在 Cloudflare Zero Trust 为该隧道绑定的公网域名 (用于 Host 和 SNI，例如 argo.yourdomain.com):"
    read -r ARGO_DOMAIN
    if [ -z "$ARGO_DOMAIN" ]; then
        echo "固定隧道必须输入绑定的域名才能生成正确的节点链接！"
        exit 1
    fi
    cloudflared service install "$CF_TOKEN"
    systemctl start cloudflared
    systemctl enable cloudflared
    echo "固定隧道已作为系统服务启动并在后台运行。"
    echo "⚠️ 提示: 请确保在 CF 仪表板中，将该域名的流量路由指向 http://localhost:$LOCAL_PORT"
    REMARK="Argo固定节点"
fi

# 6. 对 Path 进行 URL 编码
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$WS_PATH'''))" 2>/dev/null || echo "${WS_PATH//\//%2F}")

# 7. 打印最终的 VLESS 链接
VLESS_LINK="vless://${UUID}@${PREFERRED_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&alpn=http%2F1.1&insecure=0&allowInsecure=0&type=ws&host=${ARGO_DOMAIN}&path=${ENCODED_PATH}#${REMARK}"

echo ""
echo "================================================="
echo "Argo 隧道及 VLESS 节点信息："
echo ""
echo "后端监听端口: $LOCAL_PORT"
echo "VLESS 节点链接:"
echo "$VLESS_LINK"
echo ""
echo "================================================="
