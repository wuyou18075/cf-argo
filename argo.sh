#!/bin/bash

# 1. 确保安装必要的依赖
apt-get update -y
apt-get install -y wget curl openssl

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
openssl ecparam -genkey -name prime256v1 -out apple_private.key
openssl req -new -x509 -days 36500 -key apple_private.key -out apple_cert.crt -subj "/C=US/ST=California/L=Cupertino/O=Apple Inc./CN=www.apple.com"

# 4. 定义死变量（优选域名和SNI）
PREFERRED_DOMAIN="5cm.cf.090227.xyz"
SNI="www.apple.com"

# 5. 交互输入 Token
echo "请输入 Cloudflare Token (直接回车则使用临时隧道):"
read -r CF_TOKEN

# 6. 判断并启动 Argo 隧道
if [ -z "$CF_TOKEN" ]; then
    echo "未输入 Token，正在启动临时隧道..."
    # 默认将本地 8080 端口映射出去
    nohup cloudflared tunnel --url http://localhost:8080 > argo_temp.log 2>&1 &
    sleep 5
    echo "临时隧道启动成功！分配的域名如下："
    grep -o 'https://[-0-9a-z]*\.trycloudflare\.com' argo_temp.log
else
    echo "检测到 Token，正在配置并启动固定隧道..."
    cloudflared service install "$CF_TOKEN"
    systemctl start cloudflared
    systemctl enable cloudflared
    echo "固定隧道已作为系统服务启动并在后台运行。"
fi

# 7. 打印配置结果供客户端组合使用
echo "================================================="
echo "Argo 隧道节点搭建完成！"
echo "优选域名: $PREFERRED_DOMAIN"
echo "伪装 SNI: $SNI"
echo "证书私钥文件: $(pwd)/apple_private.key"
echo "证书公钥文件: $(pwd)/apple_cert.crt"
echo "================================================="
