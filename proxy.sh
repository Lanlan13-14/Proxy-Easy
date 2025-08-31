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
ACME_INSTALL_PATH="$HOME/.acme.sh"
ACME_CMD=""

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

# 函数：获取当前 SSH 端口
get_ssh_port() {
    local ssh_port="22"
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -E "^Port\s+[0-9]+" /etc/ssh/sshd_config | awk '{print $2}' | head -1)
        ssh_port=${ssh_port:-22}
    fi
    echo "$ssh_port"
}

# 函数：配置防火墙（仅为 HTTP 验证）
configure_firewall() {
    local ssh_port=$(get_ssh_port)
    if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
        if ! sudo ufw status | grep -q "$ssh_port/tcp"; then
            sudo ufw allow "$ssh_port"/tcp comment 'Allow SSH' >/dev/null 2>&1 || echo -e "${YELLOW}警告: 无法添加 UFW $ssh_port/tcp 规则。${NC}" >&2
        fi
        if ! sudo ufw status | grep -q "80/tcp"; then
            sudo ufw allow 80/tcp comment 'Allow HTTP' >/dev/null 2>&1 || echo -e "${YELLOW}警告: 无法添加 UFW 80/tcp 规则。${NC}" >&2
        fi
        if ! sudo ufw status | grep -q "443/tcp"; then
            sudo ufw allow 443/tcp comment 'Allow HTTPS' >/dev/null 2>&1 || echo -e "${YELLOW}警告: 无法添加 UFW 443/tcp 规则。${NC}" >&2
        fi
        echo -e "${GREEN}✅ UFW 规则已更新，开放 $ssh_port, 80 和 443 端口。${NC}"
    fi
}

# 函数：安装 acme.sh 和 socat
install_acme() {
    if ! command -v socat &>/dev/null; then
        echo -e "${GREEN}安装 socat 依赖...${NC}"
        sudo apt update >/dev/null 2>&1
        sudo apt install -y socat >/dev/null 2>&1 || { echo -e "${RED}❌ 错误：安装 socat 失败，请检查网络或包管理器。${NC}" >&2; return 1; }
        echo -e "${GREEN}✅ socat 安装完成。${NC}"
    fi
    if [ ! -d "$ACME_INSTALL_PATH" ]; then
        curl -fsSL https://get.acme.sh | sh -s -- home "$ACME_INSTALL_PATH" >/dev/null 2>&1 || { echo -e "${RED}❌ 错误：下载 acme.sh 失败，请检查网络连接${NC}" >&2; return 1; }
        echo -e "${GREEN}✅ acme.sh 下载完成。${NC}"
    fi
    export PATH="$ACME_INSTALL_PATH:$PATH"
    ACME_CMD=$(command -v acme.sh)
    if [ -z "$ACME_CMD" ]; then
        echo -e "${RED}❌ 错误：找不到 acme.sh 命令。请检查安装或 PATH。${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}✅ 找到 acme.sh 可执行文件。${NC}"
}

# 函数：停止 Caddy
stop_caddy_for_cert() {
    echo -e "${GREEN}停止 Caddy 以释放 80 端口...${NC}"
    pkill caddy >/dev/null 2>&1
    sleep 2
    if pgrep caddy >/dev/null; then
        echo -e "${RED}错误：无法停止 Caddy 进程，请检查！${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Caddy 已停止。${NC}"
}

# 函数：启动 Caddy
start_caddy_after_cert() {
    echo -e "${GREEN}启动 Caddy...${NC}"
    if command -v caddy &>/dev/null && [ -f "$CADDYFILE" ]; then
        caddy start --config "$CADDYFILE" >/dev/null 2>&1
        if pgrep caddy >/dev/null; then
            echo -e "${GREEN}✅ Caddy 已启动。${NC}"
        else
            echo -e "${RED}错误：Caddy 启动失败，请检查配置文件 $CADDYFILE！${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}警告：Caddy 未安装或 Caddyfile 不存在，跳过启动。${NC}"
    fi
}

# 函数：显示菜单
show_menu() {
    echo -e "${YELLOW}欢迎使用 Proxy-Easy - Caddy 反向代理管理脚本${NC}"
    echo "1. 🚀 安装 Caddy"
    echo "2. 📝 新建 Caddy 配置"
    echo "3. 🔒 申请证书"
    echo "4. 🛠️ 管理证书"
    echo "5. 🛠️ 管理配置"
    echo "6. ▶️ 启动 Caddy"
    echo "7. 🔄 重启 Caddy"
    echo "8. ♻️ 重载配置"
    echo "9. ⏹️ 停止 Caddy"
    echo "10. 📥 更新脚本"
    echo "11. ❌ 删除选项"
    echo "12. 👋 退出"
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
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | sudo tee /etc/apt/sources.list.d/caddy.list
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
        read -p "选择证书编号 (或输入新域名以通过验证): " cert_choice
        if [[ $cert_choice =~ ^[0-9]+$ ]]; then
            domain=$(ls "$CERT_DIR" | sed -n "${cert_choice}p")
            cert_path="$CERT_DIR/$domain/fullchain.pem"
            key_path="$CERT_DIR/$domain/privkey.key"
            if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                echo -e "${RED}错误：未找到证书文件（$cert_path 或 $key_path）！${NC}"
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
        config_name="caddy_[$(date +%s)].conf"
    else
        site_address="$domain"
        if [[ $caddy_port != "$standard_port" ]]; then
            site_address="$domain:$caddy_port"
        fi
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

# 函数：申请证书
config_cert() {
    echo -e "${GREEN}🔒 申请证书${NC}"
    echo "选择验证方式:"
    echo "1. DNS 验证"
    echo "2. HTTP 验证"
    read -p "请输入选项 (1 或 2): " validate_method
    if [[ ! $validate_method =~ ^[1-2]$ ]]; then
        echo -e "${RED}错误：无效的验证方式！${NC}"
        return 1
    fi
    if [[ $validate_method == "1" ]]; then
        echo "运行 cert-easy 进行 DNS 验证..."
        sudo bash -c "wget -O /usr/local/bin/cert-easy https://raw.githubusercontent.com/Lanlan13-14/Cert-Easy/refs/heads/main/acme.sh && chmod +x /usr/local/bin/cert-easy && cert-easy"
        return $?
    fi
    # HTTP 验证
    read -p "请输入域名: " domain
    read -p "请输入用于 Let's Encrypt 的电子邮件地址: " email
    if [[ -z "$email" ]]; then
        echo -e "${YELLOW}警告：未提供电子邮件地址，将使用默认设置申请证书。${NC}"
    fi
    custom_cert_path="$CERT_DIR/$domain/fullchain.pem"
    custom_key_path="$CERT_DIR/$domain/privkey.key"
    if [[ -f "$custom_cert_path" && -f "$custom_key_path" ]]; then
        echo -e "${YELLOW}警告：域名 $domain 的证书已存在，无需重新生成。${NC}"
        return 0
    fi
    sudo mkdir -p "$CERT_DIR/$domain"
    check_domain_resolution "$domain" || return 1
    check_port 80 || return 1
    configure_firewall
    install_acme || return 1
    stop_caddy_for_cert || return 1
    echo "HTTP 验证将通过 acme.sh 自动完成，请确保 $domain 已指向本服务器且 80 端口开放。"
    if ! "$ACME_CMD" --issue --standalone -d "$domain" --server letsencrypt --email "$email" --force; then
        echo -e "${RED}❌ 错误：HTTP 验证证书申请失败。${NC}" >&2
        "$ACME_CMD" --revoke -d "$domain" --server letsencrypt >/dev/null 2>&1 || true
        "$ACME_CMD" --remove -d "$domain" --server letsencrypt >/dev/null 2>&1 || true
        sudo rm -rf "$CERT_DIR/$domain"
        start_caddy_after_cert
        return 1
    fi
    if sudo "$ACME_CMD" --installcert -d "$domain" \
        --fullchain-file "$custom_cert_path" \
        --key-file "$custom_key_path" \
        --reloadcmd "caddy reload --config $CADDYFILE 2>/dev/null || true"; then
        sudo chmod 600 "$custom_key_path" >/dev/null 2>&1 || echo -e "${YELLOW}警告：设置私钥文件权限失败。${NC}" >&2
        sudo chown root:root "$custom_key_path" >/dev/null 2>&1 || echo -e "${YELLOW}警告：设置私钥文件所有者失败。${NC}" >&2
        echo "证书 $domain 配置成功，存储在 $CERT_DIR/$domain/"
    else
        echo -e "${RED}❌ 错误：证书安装失败！${NC}" >&2
        sudo rm -rf "$CERT_DIR/$domain"
        start_caddy_after_cert
        return 1
    fi
    start_caddy_after_cert
    sudo "$ACME_CMD" --install-cronjob --pre-hook "pkill caddy" --post-hook "caddy start --config $CADDYFILE" >/dev/null 2>&1 || echo -e "${YELLOW}警告：配置 acme.sh 自动续期任务失败，请手动运行 'sudo $ACME_CMD --install-cronjob'。${NC}" >&2
    echo -e "${GREEN}✅ 自动续期已通过 acme.sh 配置（包含 Caddy 停止/启动）。${NC}"
}

# 函数：管理证书
manage_cert() {
    echo -e "${GREEN}🛠️ 管理证书${NC}"
    echo "可用证书:"
    list_certs
    read -p "选择证书编号: " cert_choice
    if [[ ! $cert_choice =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：请输入有效的证书编号！${NC}"
        return 1
    fi
    domain=$(ls "$CERT_DIR" | sed -n "${cert_choice}p")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}错误：未找到选中的证书！${NC}"
        return 1
    fi
    echo "选择操作:"
    echo "1. 删除证书"
    echo "2. 手动续签证书（HTTP 验证使用 acme.sh，DNS 验证使用 cert-easy）"
    echo "3. 强制续签证书（仅限 HTTP 验证）"
    echo "4. 开启 HTTP 证书自动续签"
    echo "5. 关闭 HTTP 证书自动续签"
    read -p "请输入选项 (1-5): " op
    case $op in
        1)
            echo -e "${YELLOW}警告：将删除 $domain 的证书和相关记录！${NC}"
            read -p "确认删除 (y/n): " confirm
            if [[ $confirm == "y" ]]; then
                sudo rm -rf "$CERT_DIR/$domain"
                if [[ -f "$ACME_INSTALL_PATH/acme.sh" ]]; then
                    "$ACME_CMD" --revoke -d "$domain" --server letsencrypt >/dev/null 2>&1 || true
                    "$ACME_CMD" --remove -d "$domain" --server letsencrypt >/dev/null 2>&1 || true
                fi
                echo -e "${GREEN}证书 $domain 已删除。${NC}"
            fi
            ;;
        2)
            echo -e "${YELLOW}提示：续签方式取决于证书的验证方式（HTTP 使用 acme.sh，DNS 使用 cert-easy）。${NC}"
            if [[ -f "$CERT_DIR/$domain/fullchain.pem" && -f "$CERT_DIR/$domain/privkey.key" ]]; then
                if [[ -f "$ACME_INSTALL_PATH/$domain/$domain.conf" ]]; then
                    # HTTP 验证的证书
                    install_acme || return 1
                    stop_caddy_for_cert || return 1
                    if "$ACME_CMD" --renew -d "$domain" --server letsencrypt; then
                        echo -e "${GREEN}证书 $domain 续签成功（HTTP 验证）。${NC}"
                    else
                        echo -e "${RED}错误：证书续签失败（HTTP 验证）！${NC}"
                        start_caddy_after_cert
                        return 1
                    fi
                    start_caddy_after_cert
                else
                    # DNS 验证的证书
                    sudo bash -c "wget -O /usr/local/bin/cert-easy https://raw.githubusercontent.com/Lanlan13-14/Cert-Easy/refs/heads/main/acme.sh && chmod +x /usr/local/bin/cert-easy && cert-easy --renew -d $domain"
                    if [[ $? -eq 0 ]]; then
                        echo -e "${GREEN}证书 $domain 续签成功（DNS 验证）。${NC}"
                    else
                        echo -e "${RED}错误：证书续签失败（DNS 验证）！${NC}"
                        return 1
                    fi
                fi
            else
                echo -e "${RED}错误：未找到 $domain 的证书文件！${NC}"
                return 1
            fi
            ;;
        3)
            echo -e "${YELLOW}提示：强制续签仅适用于通过 HTTP 验证的证书。${NC}"
            install_acme || return 1
            if [[ -f "$CERT_DIR/$domain/fullchain.pem" && -f "$CERT_DIR/$domain/privkey.key" && -f "$ACME_INSTALL_PATH/$domain/$domain.conf" ]]; then
                stop_caddy_for_cert || return 1
                if "$ACME_CMD" --renew -d "$domain" --server letsencrypt --force; then
                    echo -e "${GREEN}证书 $domain 强制续签成功。${NC}"
                else
                    echo -e "${RED}错误：证书强制续签失败！${NC}"
                    start_caddy_after_cert
                    return 1
                fi
                start_caddy_after_cert
            else
                echo -e "${RED}错误：未找到 $domain 的证书文件或不是通过 HTTP 验证生成！${NC}"
                return 1
            fi
            ;;
        4)
            install_acme || return 1
            if sudo "$ACME_CMD" --install-cronjob --pre-hook "pkill caddy" --post-hook "caddy start --config $CADDYFILE" >/dev/null 2>&1; then
                echo -e "${GREEN}✅ HTTP 证书自动续签已开启（包含 Caddy 停止/启动）。${NC}"
            else
                echo -e "${RED}错误：配置自动续签任务失败，请手动运行 'sudo $ACME_CMD --install-cronjob'。${NC}" >&2
                return 1
            fi
            ;;
        5)
            install_acme || return 1
            if sudo "$ACME_CMD" --remove-cronjob >/dev/null 2>&1; then
                echo -e "${GREEN}✅ HTTP 证书自动续签已关闭。${NC}"
            else
                echo -e "${RED}错误：关闭自动续签任务失败，请手动检查 crontab。${NC}" >&2
                return 1
            fi
            ;;
        *)
            echo -e "${RED}错误：无效的操作！${NC}"
            return 1
            ;;
    esac
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
        2) vim "$CONFIG_DIR/$selected_config" ;;
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
}
EOF
    shopt -s nullglob
    for config in "$CONFIG_DIR"/caddy_*.conf; do
        if [ -f "$config" ]; then
            echo -e "${GREEN}合并配置文件: $config${NC}"
            sed '/^[[:space:]]*$/d' "$config" >> "$CADDYFILE"
        fi
    done
    shopt -u nullglob
    if command -v caddy &>/dev/null; then
        caddy fmt --overwrite "$CADDYFILE" > /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}Caddyfile 已格式化。${NC}"
        else
            echo -e "${YELLOW}警告：Caddyfile 格式化失败，可能影响美观但不影响功能。${NC}"
        fi
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
        4) manage_cert ;;
        5) manage_config ;;
        6) start_caddy ;;
        7) restart_caddy ;;
        8) reload_caddy ;;
        9) stop_caddy ;;
        10) update_script ;;
        11) delete_options ;;
        12) echo -e "${YELLOW}👋 退出。下次使用输入 proxy-easy${NC}"; exit 0 ;;
        *) echo "无效选项。" ;;
    esac
done