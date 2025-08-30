#!/bin/bash

# 脚本名称：proxy-easy
# 描述：基于Caddy的反向代理管理脚本

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 更新地址
UPDATE_URL="https://raw.githubusercontent.com/Lanlan13-14/Proxy-Easy/refs/heads/main/proxy.sh"

# Caddy 配置目录
CONFIG_DIR="$HOME/.caddy_configs"
CADDYFILE="$CONFIG_DIR/Caddyfile"
CERT_DIR="/etc/ssl/acme"
CADDY_CERT_SUBDIR="certificates/acme-v02.api.letsencrypt.org-directory"

# 确保目录存在
sudo mkdir -p "$CERT_DIR"
mkdir -p "$CONFIG_DIR"

# 函数：检查域名解析
check_domain_resolution() {
    local domain=$1
    echo -e "${GREEN}检查域名 $domain 的解析...${NC}"
    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$domain" A)
        local server_ip=$(curl -s ifconfig.me)
        if [[ -z "$resolved_ip" ]]; then
            echo -e "${RED}错误：域名 $domain 未解析到任何 IP 地址！${NC}"
            return 1
        elif [[ "$resolved_ip" != *"$server_ip"* ]]; then
            echo -e "${YELLOW}警告：域名 $domain 解析到 $resolved_ip，但服务器公网 IP 是 $server_ip，可能需要更新 DNS 记录。${NC}"
        else
            echo -e "${GREEN}域名 $domain 已正确解析到 $resolved_ip。${NC}"
        fi
    else
        echo -e "${YELLOW}警告：未安装 dig，无法检查域名解析，请手动确保 $domain 指向服务器 IP。${NC}"
    fi
    return 0
}

# 函数：检查端口
check_port() {
    local port=$1
    echo -e "${GREEN}检查端口 $port 是否开放...${NC}"
    if command -v nc &>/dev/null; then
        nc -z -w 5 127.0.0.1 "$port" > /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}端口 $port 已开放。${NC}"
        else
            echo -e "${RED}错误：端口 $port 未开放，请检查防火墙或安全组设置！${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}警告：未安装 nc，无法检查端口状态，请手动确保 $port 端口开放。${NC}"
    fi
    return 0
}

# 函数：显示菜单
show_menu() {
    echo -e "${YELLOW}欢迎使用 Proxy-Easy - Caddy 反向代理管理脚本${NC}"
    echo "1. 🚀 安装 Caddy"
    echo "2. 📝 新建 Caddy 配置"
    echo "3. 🔒 配置证书"
    echo "4. 🛠️ 管理配置"
    echo "5. ▶️ 启动 Caddy"
    echo "6. 🔄 重启 Caddy"
    echo "7. ♻️ 重载配置"
    echo "8. ⏹️ 停止 Caddy"
    echo "9. 📥 更新脚本"
    echo "10. ❌ 删除选项"
    echo "11. 👋 退出"
    echo -n "请选择选项: "
}

# 安装 Caddy
install_caddy() {
    echo -e "${GREEN}🚀 安装 Caddy...${NC}"
    if command -v caddy &>/dev/null; then
        echo "Caddy 已安装。"
        return
    fi

    sudo apt update
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg

    # 添加 Cloudsmith 最新 GPG key
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    # 添加 Caddy 官方仓库
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | sudo tee /etc/apt/sources.list.d/caddy.list

    # 安装 Caddy
    sudo apt update
    sudo apt install -y caddy

    echo "Caddy 安装完成。"
}

# 函数：新建配置
new_config() {
    echo -e "${GREEN}📝 新建 Caddy 配置${NC}"
    read -p "1. 后端地址 (默认 127.0.0.1): " backend_addr
    backend_addr=${backend_addr:-127.0.0.1}
    
    read -p "2. 后端监听端口: " backend_port
    
    read -p "3. Caddy 监听端口: " caddy_port
    
    read -p "4. 是否开启 TLS (y/n): " enable_tls
    tls_config=""
    domain=""
    if [[ $enable_tls == "y" ]]; then
        echo "可用证书选项:"
        list_certs
        read -p "选择证书编号 (或输入新域名以通过 Caddy HTTP 验证): " cert_choice
        if [[ $cert_choice =~ ^[0-9]+$ ]]; then
            domain=$(ls "$CERT_DIR" | sed -n "${cert_choice}p")
            # 检查 Caddy 默认路径
            caddy_cert_path="$CERT_DIR/$CADDY_CERT_SUBDIR/$domain/$domain.crt"
            caddy_key_path="$CERT_DIR/$CADDY_CERT_SUBDIR/$domain/$domain.key"
            # 检查自定义路径
            custom_cert_path="$CERT_DIR/$domain/fullchain.pem"
            custom_key_path="$CERT_DIR/$domain/privkey.key"
            if [[ -f "$caddy_cert_path" && -f "$caddy_key_path" ]]; then
                cert_path="$caddy_cert_path"
                key_path="$caddy_key_path"
            elif [[ -f "$custom_cert_path" && -f "$custom_key_path" ]]; then
                cert_path="$custom_cert_path"
                key_path="$custom_key_path"
            else
                echo -e "${RED}错误：未找到证书文件（$caddy_cert_path 或 $custom_cert_path）或密钥文件（$caddy_key_path 或 $custom_key_path）！${NC}"
                return 1
            fi
            tls_config="tls $cert_path $key_path"
        else
            domain="$cert_choice"
            read -p "请输入用于 Let's Encrypt 的电子邮件地址: " email
            if [[ -z "$email" ]]; then
                echo -e "${YELLOW}警告：未提供电子邮件地址，将使用 Caddy 默认设置申请证书。${NC}"
                tls_config="tls"
            else
                tls_config="tls $email"
            fi
        fi
    fi
    
    read -p "5. 是否开启 H3 (QUIC) 支持 (y/n): " enable_h3
    if [[ $enable_h3 != "y" ]]; then
        touch "$CONFIG_DIR/.h3_disabled"
    else
        rm -f "$CONFIG_DIR/.h3_disabled"
    fi
    
    read -p "6. 是否开启 WS 支持 (y/n): " enable_ws
    ws_config=""
    if [[ $enable_ws == "y" ]]; then
        ws_config="handle_path /ws* { reverse_proxy $backend_addr:$backend_port }"
    fi
    
    read -p "7. 是否开启双栈监听 (y/n): " enable_dual
    bind_config=""
    if [[ $enable_dual != "y" ]]; then
        bind_config="bind 0.0.0.0"
    fi
    
    standard_port=$([[ $enable_tls == "y" ]] && echo 443 || echo 80)
    if [ -z "$domain" ]; then
        if [[ $enable_dual == "y" ]]; then
            site_address=":$caddy_port"
        else
            site_address="0.0.0.0:$caddy_port"
        fi
        # 如果没有域名，使用时间戳命名
        config_name="caddy_[$(date +%s)].conf"
    else
        site_address="$domain"
        if [[ $caddy_port != "$standard_port" ]]; then
            site_address="$domain:$caddy_port"
        fi
        # 使用域名命名，包裹在 [] 中
        config_name="caddy_[$domain].conf"
    fi
    
    echo "8. 确认生成配置:"
    echo "后端: $backend_addr:$backend_port"
    echo "Caddy 端口: $caddy_port"
    echo "域名: $domain"
    echo "TLS: $tls_config"
    echo "H3: $enable_h3"
    echo "WS: $ws_config"
    echo "双栈: $enable_dual"
    echo "配置文件名: $config_name"
    read -p "确认 (y/n): " confirm
    if [[ $confirm == "y" ]]; then
        # 生成配置文件，确保无多余空行
        cat <<EOF > "$CONFIG_DIR/$config_name"
$site_address {
$tls_config
$bind_config
reverse_proxy $backend_addr:$backend_port
$ws_config
}
EOF
        echo "配置 $config_name 生成成功。"
    fi
}

# 函数：列出证书
list_certs() {
    certs=$(ls "$CERT_DIR" 2>/dev/null)
    if [[ -z $certs ]]; then
        echo "无可用证书。"
        return
    fi
    i=1
    for cert in $certs; do
        echo "[$i] $cert"
        ((i++))
    done
}

# 函数：配置证书
config_cert() {
    echo -e "${GREEN}🔒 配置证书${NC}"
    read -p "选择验证方式 (1: DNS, 2: HTTP): " validate_method
    read -p "域名: " domain
    
    # 检查现有证书
    caddy_cert_path="$CERT_DIR/$CADDY_CERT_SUBDIR/$domain/$domain.crt"
    caddy_key_path="$CERT_DIR/$CADDY_CERT_SUBDIR/$domain/$domain.key"
    custom_cert_path="$CERT_DIR/$domain/fullchain.pem"
    custom_key_path="$CERT_DIR/$domain/privkey.key"
    if [[ -f "$caddy_cert_path" && -f "$caddy_key_path" ]] || [[ -f "$custom_cert_path" && -f "$custom_key_path" ]]; then
        echo -e "${YELLOW}警告：域名 $domain 的证书已存在，无需重新生成。${NC}"
        return 0
    fi
    
    # 检查域名解析和 80 端口（仅 HTTP 验证）
    if [[ $validate_method == "2" ]]; then
        check_domain_resolution "$domain" || return 1
        check_port 80 || return 1
        read -p "请输入用于 Let's Encrypt 的电子邮件地址: " email
        if [[ -z "$email" ]]; then
            echo -e "${YELLOW}警告：未提供电子邮件地址，将使用 Caddy 默认设置申请证书。${NC}"
            tls_config="tls"
        else
            tls_config="tls $email"
        fi
    fi
    
    sudo mkdir -p "$CERT_DIR/$domain"
    
    if [[ $validate_method == "1" ]]; then
        echo "运行 cert-easy 进行 DNS 验证..."
        sudo bash -c "wget -O /usr/local/bin/cert-easy https://raw.githubusercontent.com/Lanlan13-14/Cert-Easy/refs/heads/main/acme.sh && chmod +x /usr/local/bin/cert-easy && cert-easy"
        if [[ $? -eq 0 ]]; then
            cert-easy --install-cert -d "$domain" \
                --fullchain-file "$custom_cert_path" \
                --key-file "$custom_key_path" \
                --cert-file "$CERT_DIR/$domain/cert.pem" \
                --ca-file "$CERT_DIR/$domain/chain.pem" \
                --reloadcmd "caddy reload --config $CADDYFILE"
            echo "证书 $domain 配置成功，存储在 $CERT_DIR/$domain，支持自动续签。"
        else
            echo -e "${RED}DNS 验证证书申请失败，请检查 cert-easy 日志或配置。${NC}"
            sudo rm -rf "$CERT_DIR/$domain"
            return 1
        fi
    else
        echo "HTTP 验证将通过 Caddy 自动完成，请确保 $domain 已指向本服务器且 80 端口开放。"
        temp_config="/tmp/caddy_temp_config"
        cat <<EOF > "$temp_config"
{
  storage file_system $CERT_DIR
}
$domain {
  $tls_config
  respond "HTTP validation placeholder"
}
EOF
        echo "临时配置文件内容："
        cat -n "$temp_config"
        echo "正在触发 Caddy HTTP 验证..."
        caddy run --config "$temp_config" --adapter caddyfile &
        caddy_pid=$!
        sleep 10  # 等待 Caddy 完成验证
        # 检查 PID 是否有效
        if ps -p $caddy_pid > /dev/null; then
            kill $caddy_pid
            wait $caddy_pid 2>/dev/null
        else
            echo -e "${YELLOW}警告：Caddy 进程 $caddy_pid 已提前退出，可能已完成证书申请。${NC}"
        fi
        # 检查 Caddy 默认路径的证书
        if [[ -f "$caddy_cert_path" && -f "$caddy_key_path" ]]; then
            echo "证书 $domain 配置成功，存储在 $CERT_DIR/$CADDY_CERT_SUBDIR/$domain/"
            # 复制到自定义路径，保持格式一致
            sudo mkdir -p "$CERT_DIR/$domain"
            sudo cp "$caddy_cert_path" "$custom_cert_path"
            sudo cp "$caddy_key_path" "$custom_key_path"
            echo "证书已复制到 $CERT_DIR/$domain/ 作为 fullchain.pem 和 privkey.key"
        else
            echo -e "${RED}HTTP 验证证书申请失败，请检查以下内容：${NC}"
            echo -e "${RED}1. 域名 $domain 是否正确解析到本服务器 IP。${NC}"
            echo -e "${RED}2. 80 端口是否开放（检查防火墙或云服务商安全组）。${NC}"
            echo -e "${RED}3. Caddy 日志是否有其他错误。${NC}"
            sudo rm -rf "$CERT_DIR/$domain"
            return 1
        fi
        rm -f "$temp_config"
    fi
}

# 函数：管理配置
manage_config() {
    echo -e "${GREEN}🛠️ 管理配置${NC}"
    configs=$(ls "$CONFIG_DIR" 2>/dev/null)
    if [[ -z $configs ]]; then
        echo "无配置。"
        return
    fi
    i=1
    for config in $configs; do
        echo "[$i] $config"
        ((i++))
    done
    read -p "选择配置编号: " choice
    selected_config=$(ls "$CONFIG_DIR" | sed -n "${choice}p")
    
    echo "1. 查看配置"
    echo "2. 修改配置"
    echo "3. 删除配置"
    read -p "选择操作: " op
    case $op in
        1) cat "$CONFIG_DIR/$selected_config" ;;
        2) vim "$CONFIG_DIR/$selected_config" ;;  # 假设有 vim，或用 nano
        3) rm "$CONFIG_DIR/$selected_config" ;;
    esac
}

# 函数：启动 Caddy
start_caddy() {
    echo -e "${GREEN}▶️ 启动 Caddy...${NC}"
    combine_configs
    caddy run --config "$CADDYFILE" --watch &
}

# 函数：重启 Caddy
restart_caddy() {
    echo -e "${GREEN}🔄 重启 Caddy...${NC}"
    stop_caddy
    start_caddy
}

# 函数：重载配置
reload_caddy() {
    echo -e "${GREEN}♻️ 重载配置...${NC}"
    combine_configs
    caddy reload --config "$CADDYFILE"
}

# 函数：停止 Caddy
stop_caddy() {
    echo -e "${RED}⏹️ 停止 Caddy...${NC}"
    pkill caddy
}

# 函数：合并所有配置到 Caddyfile
combine_configs() {
    echo -e "${GREEN}正在合并配置到 $CADDYFILE...${NC}"
    > "$CADDYFILE"
    cat <<EOF >> "$CADDYFILE"
{
	storage file_system $CERT_DIR
EOF
    if [ -f "$CONFIG_DIR/.h3_disabled" ]; then
        cat <<EOF >> "$CADDYFILE"
	servers {
		protocols h1 h2
	}
EOF
    fi
    cat <<EOF >> "$CADDYFILE"
}
EOF
    shopt -s nullglob
    for config in "$CONFIG_DIR"/caddy_*.conf; do
        if [ -f "$config" ]; then
            echo -e "${GREEN}合并配置文件: $config${NC}"
            # 清理空行和多余空格
            sed '/^[[:space:]]*$/d' "$config" >> "$CADDYFILE"
        fi
    done
    shopt -u nullglob
    if command -v caddy &>/dev/null; then
        # 格式化 Caddyfile
        caddy fmt --overwrite "$CADDYFILE" > /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}Caddyfile 已格式化。${NC}"
        else
            echo -e "${YELLOW}警告：Caddyfile 格式化失败，可能影响美观但不影响功能。${NC}"
        fi
        # 验证 Caddyfile 语法
        caddy validate --config "$CADDYFILE" > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Caddyfile 语法验证失败，请检查 $CADDYFILE 内容。${NC}"
            cat -n "$CADDYFILE"
            exit 1
        else
            echo -e "${GREEN}Caddyfile 语法验证通过。${NC}"
        fi
    else
        echo -e "${YELLOW}未安装 Caddy，无法验证 Caddyfile 语法。${NC}"
    fi
}

# 函数：更新脚本
update_script() {
    echo -e "${GREEN}📥 更新脚本...${NC}"
    backup_file="$0.bak"
    cp "$0" "$backup_file"
    echo "备份完成: $backup_file"
    
    curl -o "$0" "$UPDATE_URL"
    echo "从 $UPDATE_URL 拉取更新完成。"
    
    if bash -n "$0"; then
        echo "语法检查通过。"
        rm "$backup_file"
        echo "删除备份。"
        exec "$0" "$@"
    else
        echo "语法检查失败，回滚。"
        mv "$backup_file" "$0"
    fi
}

# 函数：删除选项
delete_options() {
    echo -e "${RED}❌ 删除选项${NC}"
    echo "1. 删除本脚本"
    echo "2. 删除 Caddy 及本脚本"
    read -p "选择: " del_choice
    if [[ $del_choice == "1" ]]; then
        rm "$0"
        echo "脚本已删除。"
    elif [[ $del_choice == "2" ]]; then
        echo -e "${RED}🗑️ 卸载 Caddy 及相关配置...${NC}"
        sudo systemctl disable caddy.service --now 2>/dev/null
        sudo apt purge -y caddy
        sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy.list
        rm -rf "$CONFIG_DIR" "$CERT_DIR"
        rm "$0"
        echo "Caddy 及脚本相关配置已删除。"
    fi
}

# 主循环
while true; do
    show_menu
    read choice
    case $choice in
        1) install_caddy ;;
        2) new_config ;;
        3) config_cert ;;
        4) manage_config ;;
        5) start_caddy ;;
        6) restart_caddy ;;
        7) reload_caddy ;;
        8) stop_caddy ;;
        9) update_script ;;
        10) delete_options ;;
        11) echo -e "${YELLOW}👋 退出。下次使用输入 proxy-easy${NC}"; exit 0 ;;
        *) echo "无效选项。" ;;
    esac
done