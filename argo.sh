#!/bin/bash

# 1. 检测并确保必要的依赖
echo "正在检测基础依赖 (wget, curl, python3)..."
NEED_INSTALL=0
command -v wget >/dev/null 2>&1 || NEED_INSTALL=1
command -v curl >/dev/null 2>&1 || NEED_INSTALL=1
command -v python3 >/dev/null 2>&1 || NEED_INSTALL=1

if [ "$NEED_INSTALL" -eq 1 ]; then
    echo "发现缺失依赖，正在检测系统包管理器并尝试安装..."
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
        echo "未找到支持的包管理器，请手动安装 wget, curl 和 python3 后重试。"
        exit 1
    fi
else
    echo "基础依赖已全部就绪，跳过安装环节。"
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

    # ================= WARP 备选方案与卸载逻辑 =================
    if [ -z "$ARGO_DOMAIN" ]; then
        echo "================ 错误 ================"
        echo "临时域名获取失败 (可能是 IP 被拦截，或该免费虚拟机的出站网络被严格限制)。"
        
        read -r -p "是否套用 WARP 改变出站 IP 并重试？(失败将自动还原环境) (y/n，回车默认 y): " USE_WARP
        USE_WARP=${USE_WARP:-y}
        
        if [[ "$USE_WARP" == "y" || "$USE_WARP" == "Y" ]]; then
            ORIGINAL_IP=$(curl -s -m 5 -4 https://ifconfig.me || curl -s -m 5 -4 https://api.ipify.org || echo "未知")
            echo ">>> 当前原始出站 IP: $ORIGINAL_IP"
            echo "正在自动安装 Cloudflare WARP 官方客户端..."
            
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
                echo "当前系统的包管理器暂不支持自动化安装官方 WARP。"
                exit 1
            fi

            echo "尝试强制启动 WARP 守护进程 (Daemon)..."
            # 兼容精简虚拟机的启动方式
            systemctl start warp-svc 2>/dev/null || service warp-svc start 2>/dev/null || /usr/bin/warp-svc >/dev/null 2>&1 &
            sleep 3

            echo "正在注册并启动 WARP 接管网络..."
            warp-cli --accept-tos registration new 2>/dev/null
            warp-cli --accept-tos connect 2>/dev/null
            
            echo "等待 8 秒让 WARP 网络连通并分配 IP..."
            sleep 8
            
            NEW_IP=$(curl -s -m 5 -4 https://ifconfig.me || curl -s -m 5 -4 https://api.ipify.org || echo "无法获取")
            echo ">>> 切换后的新出站 IP: $NEW_IP"

            if [ "$ORIGINAL_IP" == "$NEW_IP" ] || [ "$NEW_IP" == "无法获取" ]; then
                echo "⚠️ 警告：IP 并未发生改变，WARP 核心服务可能被当前虚拟机环境拦截运行！"
            fi
            
            echo "正在重新申请临时隧道..."
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
            
            if [ -z "$ARGO_DOMAIN" ]; then
                echo "================ 彻底失败 ================"
                echo "套用 WARP 后仍然获取失败。结论：当前免费虚拟机严格限制了出站端口或 UDP 流量，导致无法建立隧道。"
                echo "正在为您断开 WARP 并彻底卸载清理..."
                
                warp-cli --accept-tos disconnect 2>/dev/null
                
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get remove --purge -y cloudflare-warp
                    rm -f /etc/apt/sources.list.d/cloudflare-client.list
                    apt-get autoremove -y
                elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
                    PM="yum"; [ -x "$(command -v dnf)" ] && PM="dnf"
                    $PM remove -y cloudflare-warp
                    rm -f /etc/yum.repos.d/cloudflare-warp.repo
                fi
                
                echo "环境已还原到初始状态。当前机器无法白嫖临时隧道，只能使用输入 Token 的【固定隧道】。"
                exit 1
            fi
        else
            echo "已取消套用 WARP，脚本退出。"
            exit 1
        fi
    fi
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
    systemctl start cloudflared 2>/dev/null || /usr/local/bin/cloudflared service start
    echo "固定隧道已启动并在后台运行。"
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
