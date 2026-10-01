#!/usr/bin/env bash
# ==============================================================================
#  项目名称: bbr-v3-pro
#  定位: 生产级 Linux 双栈网络调优、拥塞控制与 BBR 管理系统
#  特点: 纯净无广告、无 Emoji、TCP+UDP 双栈优化、小内存防 OOM 钳位、原子化安全防砖
# ==============================================================================

set -u

# 色彩定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# 日志格式化打印函数
log_info()    { echo -e "${BLUE}[INFO]${PLAIN} $*"; }
log_success() { echo -e "${GREEN}[OK]${PLAIN} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
log_error()   { echo -e "${RED}[ERROR]${PLAIN} $*"; }

# 确保以 root 权限执行
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    exit 1
fi

# 检查系统发行版
if ! command -v apt-get &> /dev/null; then
    log_error "当前脚本仅支持基于 Debian / Ubuntu 的系统。"
    exit 1
fi

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    log_error "不支持的系统架构: $ARCH (仅支持 x86_64 与 aarch64)"
    exit 1
fi

# 核心路径常量
SYSCTL_CONF="/etc/sysctl.d/99-bbr-v3-pro.conf"
MODULES_CONF="/etc/modules-load.d/bbr-v3-pro-qdisc.conf"
SECURITY_MODPROBE_CONF="/etc/modprobe.d/99-bbr-v3-pro-security.conf"
QUICK_COMMAND_PATH="/usr/local/bin/bbr-pro"

# GitHub 仓库配置 (支持环境变量覆盖)
GITHUB_REPO="${BBR_REPO:-YOUR_USERNAME/bbr-v3-pro}"
GITHUB_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# 依赖修复与检查
check_and_install_deps() {
    local missing_deps=()
    local required_cmds=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "jq" "ip" "ss")

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_info "检测到缺失必要依赖: ${missing_deps[*]}，正在自动安装..."
        
        # 检查并释放可能被残留进程占用的 dpkg / apt 锁
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            log_warn "检测到 apt/dpkg 锁被占用，正在等待释放..."
            sleep 2
        fi

        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get update; then
            log_warn "apt-get update 过程中出现错误，正在尝试修复已知异常源..."
            rm -f /etc/apt/sources.list.d/caddy*.list /etc/apt/sources.list.d/caddy*.sources 2>/dev/null || true
            apt-get update || true
        fi

        if ! apt-get install -y "${missing_deps[@]}"; then
            log_error "自动安装依赖失败，请手动排查 apt 软件源后重试。"
            exit 1
        fi
        log_success "所有依赖环境已准备就绪。"
    fi
}

# 快捷指令自安装 (非侵入式，可配置)
setup_shortcut() {
    if [[ "${BBR_SKIP_SHORTCUT:-0}" == "1" ]]; then
        return 0
    fi
    if [[ ! -f "$QUICK_COMMAND_PATH" ]]; then
        if [[ -f "$0" ]]; then
            cp -f "$0" "$QUICK_COMMAND_PATH"
            chmod 755 "$QUICK_COMMAND_PATH"
            log_info "已注册系统快捷指令: bbr-pro (随时可在终端输入 bbr-pro 调出管理菜单)"
        fi
    fi
}

# ==============================================================================
#  内存安全计算引擎 (Memory Safety Clamp) - 针对 512M/768M/1G 小机器防 OOM 核心算法
# ==============================================================================
get_safe_memory_limits() {
    local mem_kb
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 1048576)
    local page_size=4096

    # 1. 计算全局 TCP 内存池水位 (net.ipv4.tcp_mem，以 4KB 页面为单位)
    # min: 物理内存 10% | pressure: 物理内存 25% | max: 物理内存 40%
    TCP_MEM_MIN=$(( (mem_kb * 1024 * 10 / 100) / page_size ))
    TCP_MEM_PRESSURE=$(( (mem_kb * 1024 * 25 / 100) / page_size ))
    TCP_MEM_MAX=$(( (mem_kb * 1024 * 40 / 100) / page_size ))

    # 2. 计算单连接 Socket 缓冲区硬性物理上限 (Byte)
    # 严格钳位在物理内存的 15% 以内，杜绝多并发时打穿内存
    MAX_SOCKET_BYTES=$(( mem_kb * 1024 * 15 / 100 ))

    # 预设档位限制 (768M 机器上限约 16MB，1G 机器上限约 24MB)
    local default_cap=$(( 16 * 1024 * 1024 ))
    if (( mem_kb < 600000 )); then
        default_cap=$(( 8 * 1024 * 1024 ))
    elif (( mem_kb > 1500000 )); then
        default_cap=$(( 32 * 1024 * 1024 ))
    fi

    if (( default_cap > MAX_SOCKET_BYTES )); then
        TARGET_SOCKET_BYTES=$MAX_SOCKET_BYTES
    else
        TARGET_SOCKET_BYTES=$default_cap
    fi
}

# ==============================================================================
#  sysctl 持久化管理函数
# ==============================================================================
clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.rmem_max/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.wmem_max/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.optmem_max/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.netdev_max_backlog/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.somaxconn/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_wmem/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_rmem/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_mem/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_limit_output_bytes/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_slow_start_after_idle/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_notsent_lowat/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_autocorking/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_no_metrics_save/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_mtu_probing/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_fastopen/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_window_scaling/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_moderate_rcvbuf/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_ecn/d' "$SYSCTL_CONF"
}

# 加载队列调度内核模块
load_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"

    if ! lsmod | grep -q "^${module_name//-/_}"; then
        sudo modprobe "$module_name" 2>/dev/null || true
    fi

    if sudo sysctl -w net.core.default_qdisc="$qdisc_name" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# 应用拥塞控制算法与队列
apply_bbr_and_qdisc() {
    local algo="${1:-bbr}"
    local qdisc="${2:-fq}"

    log_info "正在配置拥塞算法 [$algo] 与队列调度 [$qdisc]..."
    load_qdisc_module "$qdisc"

    sudo sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$algo" >/dev/null 2>&1

    clean_sysctl_conf
    {
        echo "net.core.default_qdisc = $qdisc"
        echo "net.ipv4.tcp_congestion_control = $algo"
    } | sudo tee -a "$SYSCTL_CONF" >/dev/null

    sudo sysctl --system >/dev/null 2>&1

    log_success "配置已生效并持久化至: $SYSCTL_CONF"
    log_info "  当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
    log_info "  当前队列调度算法: $(sysctl -n net.core.default_qdisc)"
}

# ==============================================================================
#  核心调优方案 1: AI 网关与跨洋全栈优化 (TCP + UDP 复合双栈)
#  专为 VLESS + Hysteria 2 + cliproxyapi AI 大模型流式调用深度协同打造
# ==============================================================================
apply_ai_gateway_tuning() {
    log_info "正在计算系统物理内存边界并应用 AI 网关 & 跨洋全栈优化..."
    get_safe_memory_limits

    local algo="bbr"
    local qdisc="fq"
    local output_bytes="4194304"

    load_qdisc_module "$qdisc"

    # 1. 运行时立即应用
    sudo sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$algo" >/dev/null 2>&1
    sudo sysctl -w net.core.rmem_max="$TARGET_SOCKET_BYTES" >/dev/null 2>&1
    sudo sysctl -w net.core.wmem_max="$TARGET_SOCKET_BYTES" >/dev/null 2>&1
    sudo sysctl -w net.core.netdev_max_backlog="10000" >/dev/null 2>&1
    sudo sysctl -w net.core.somaxconn="4096" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 $TARGET_SOCKET_BYTES" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 $TARGET_SOCKET_BYTES" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_mem="$TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_limit_output_bytes="$output_bytes" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_slow_start_after_idle="0" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_window_scaling="1" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_mtu_probing="1" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_notsent_lowat="16384" >/dev/null 2>&1

    # 2. 持久化写入
    clean_sysctl_conf
    {
        echo "# bbr-v3-pro: AI Gateway & High-Throughput Cross-Pacific Tuning"
        echo "net.core.default_qdisc = $qdisc"
        echo "net.ipv4.tcp_congestion_control = $algo"
        echo ""
        echo "# UDP / QUIC Buffer (Optimized for Hysteria 2 & Caddy HTTP/3)"
        echo "net.core.rmem_max = $TARGET_SOCKET_BYTES"
        echo "net.core.wmem_max = $TARGET_SOCKET_BYTES"
        echo "net.core.netdev_max_backlog = 10000"
        echo "net.core.somaxconn = 4096"
        echo ""
        echo "# TCP Buffer & Low Latency (Optimized for VLESS & AI Model Streaming)"
        echo "net.ipv4.tcp_rmem = 4096 87380 $TARGET_SOCKET_BYTES"
        echo "net.ipv4.tcp_wmem = 4096 65536 $TARGET_SOCKET_BYTES"
        echo "net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX"
        echo "net.ipv4.tcp_limit_output_bytes = $output_bytes"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_window_scaling = 1"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "net.ipv4.tcp_notsent_lowat = 16384"
    } | sudo tee -a "$SYSCTL_CONF" >/dev/null

    log_success "AI 网关与跨洋全栈调优配置已写入：$SYSCTL_CONF"
    echo -e "  ${BOLD}核心调优摘要：${PLAIN}"
    echo -e "  - 拥塞控制 / 队列 : ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)${PLAIN}"
    echo -e "  - 单 Socket 缓冲区: ${GREEN}$((TARGET_SOCKET_BYTES / 1024 / 1024)) MB${PLAIN} (已实施小内存安全钳位)"
    echo -e "  - 全局 TCP 水位线 : ${GREEN}${TCP_MEM_MIN} / ${TCP_MEM_PRESSURE} / ${TCP_MEM_MAX} Pages${PLAIN} (最大占内存 40%)"
    echo -e "  - 网卡接收队列    : ${GREEN}10000${PLAIN} (防 Hy2 端口跳跃瞬时丢包)"
    echo -e "  - 空闲慢启动降速  : ${GREEN}已禁用 (tcp_slow_start_after_idle=0，大模型提示响应零延迟)${PLAIN}"
    echo -e "  - MTU 黑洞探测    : ${GREEN}已启用 (防跨洋大 Token 长上下文丢包)${PLAIN}"
}

# ==============================================================================
#  核心调优方案 2: 亚太短链路低延迟调优 (适用于香港 / 日本 / 新加坡等直连)
# ==============================================================================
apply_apac_tuning() {
    log_info "正在应用亚太短链路低延迟调优 (RTT < 80ms)..."
    get_safe_memory_limits

    local apac_buffer=$(( 8 * 1024 * 1024 ))
    if (( apac_buffer > MAX_SOCKET_BYTES )); then
        apac_buffer=$MAX_SOCKET_BYTES
    fi

    clean_sysctl_conf
    {
        echo "# bbr-v3-pro: APAC Low-Latency Tuning"
        echo "net.core.default_qdisc = fq"
        echo "net.ipv4.tcp_congestion_control = bbr"
        echo "net.core.rmem_max = $apac_buffer"
        echo "net.core.wmem_max = $apac_buffer"
        echo "net.ipv4.tcp_rmem = 4096 131072 $apac_buffer"
        echo "net.ipv4.tcp_wmem = 4096 16384 $apac_buffer"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_limit_output_bytes = 4194304"
    } | sudo tee -a "$SYSCTL_CONF" >/dev/null

    sudo sysctl --system >/dev/null 2>&1
    log_success "亚太机器低延迟优化已生效。"
}

# ==============================================================================
#  清空网络优化配置 (一键回滚出厂默认)
# ==============================================================================
clear_network_tuning() {
    log_info "正在清空所有自定义网络优化持久化配置..."
    sudo rm -f "$SYSCTL_CONF" "$MODULES_CONF"
    sudo sysctl --system >/dev/null 2>&1 || true
    log_success "已彻底清空配置并重载系统默认参数。"
    log_warn "部分运行态参数建议在重启系统后彻底恢复发行版初始默认值。"
}

# ==============================================================================
#  端口冲突检测小工具 (协同检查 Caddy HTTP/3 与 Hysteria 2)
# ==============================================================================
check_port_conflicts() {
    echo -e "\n${BOLD}================= 系统关键端口占用探测 =================${PLAIN}"
    local ports=("80:tcp" "443:tcp" "443:udp" "8443:tcp" "8443:udp" "18921:tcp")
    
    printf "%-12s | %-8s | %-16s | %-24s\n" "端口" "协议" "监听状态" "占用进程 (PID/名称)"
    echo "------------------------------------------------------------------------"
    
    for p in "${ports[@]}"; do
        local port="${p%%:*}"
        local proto="${p##*:}"
        local state="空闲 (可使用)"
        local pinfo="无"
        local raw=""
        
        if [ "$proto" == "tcp" ]; then
            raw=$(ss -tlpn "sport = :$port" 2>/dev/null | grep -E ":$port\b" || true)
        else
            raw=$(ss -ulpn "sport = :$port" 2>/dev/null | grep -E ":$port\b" || true)
        fi
        
        if [ -n "$raw" ]; then
            state="${RED}已占用${PLAIN}"
            pinfo=$(echo "$raw" | awk '{print $NF}' | sed -E 's/users:\(\((.*)\)\)/\1/' | head -n 1)
        else
            state="${GREEN}空闲${PLAIN}"
        fi
        printf "%-12s | %-8s | %-22b | %-24s\n" "$port" "${proto^^}" "$state" "$pinfo"
    done
    echo "------------------------------------------------------------------------"
    echo -e "${BLUE}[最佳协同实践]${PLAIN}"
    echo -e "  - Caddy 反代: 监听 TCP 80/443 (若开启 HTTP/3 独占 UDP 443)"
    echo -e "  - Hysteria 2: 监听 8443 + 端口跳跃 47000:50000 (完全避开 UDP 443，互不冲突)"
    echo -e "  - 3X-UI 面板: 监听本地 18921 (由 Caddy 本地反代，免端口直连)"
}

# ==============================================================================
#  检查 BBR / BBRv3 状态
# ==============================================================================
check_bbr_status() {
    echo -e "\n${BOLD}==================== BBR 状态与系统体检 ====================${PLAIN}"
    local cur_algo
    local cur_qdisc
    local cur_kernel
    cur_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    cur_kernel=$(uname -r)

    echo -e "当前系统内核   : ${GREEN}$cur_kernel${PLAIN}"
    echo -e "当前拥塞控制   : ${GREEN}$cur_algo${PLAIN}"
    echo -e "当前队列管理   : ${GREEN}$cur_qdisc${PLAIN}"

    local bbr_mod
    bbr_mod=$(modinfo tcp_bbr 2>/dev/null || true)
    if [ -z "$bbr_mod" ]; then
        depmod -a 2>/dev/null || true
        bbr_mod=$(modinfo tcp_bbr 2>/dev/null || true)
    fi

    local bbr_ver
    bbr_ver=$(echo "$bbr_mod" | awk '/^version:/ {print $2}')
    if [[ "$bbr_ver" == "3" ]]; then
        echo -e "BBR 模块版本   : ${GREEN}$bbr_ver (BBR v3 已激活)${PLAIN}"
    else
        echo -e "BBR 模块版本   : ${BLUE}${bbr_ver:-官方标准版 (Linux 内置 BBR)}${PLAIN}"
    fi

    local mem_total
    mem_total=$(awk '/MemTotal:/ {print int($2/1024) " MB"}' /proc/meminfo 2>/dev/null || echo "未知")
    echo -e "物理内存总量   : ${BLUE}$mem_total${PLAIN}"

    if [ -f "$SYSCTL_CONF" ]; then
        echo -e "持久化优化配置 : ${GREEN}已加载 ($SYSCTL_CONF)${PLAIN}"
    else
        echo -e "持久化优化配置 : ${YELLOW}未加载 (当前运行系统默认参数)${PLAIN}"
    fi
}

# ==============================================================================
#  原子化安全内核安装逻辑 (防砖架构)
# ==============================================================================
gh_api_get() {
    local url="$1"
    if [[ -n "$GITHUB_API_TOKEN" ]]; then
        curl -fsSL -H "Authorization: Bearer $GITHUB_API_TOKEN" -H "Accept: application/vnd.github+json" "$url"
    else
        curl -fsSL "$url"
    fi
}

install_bbrv3_kernel() {
    local profile="${1:-standard}"
    log_info "正在从 GitHub 获取 [$GITHUB_REPO] 最新发布的内核版本..."

    local base_url="https://api.github.com/repos/${GITHUB_REPO}/releases"
    local release_data
    release_data=$(gh_api_get "$base_url")

    if [[ -z "$release_data" ]]; then
        log_error "从 GitHub 获取版本清单失败，请检查网络连接。"
        return 1
    fi

    local arch_filter="x86_64"
    [[ "$ARCH" == "aarch64" ]] && arch_filter="arm64"

    local latest_tag
    latest_tag=$(echo "$release_data" | jq -r --arg filter "$arch_filter" --arg prof "$profile" '
      map(
        select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
        | select(if $prof == "max" then (.tag_name | endswith("-max")) else ((.tag_name | endswith("-max")) | not) end)
      )
      | sort_by(.published_at)
      | .[-1].tag_name // ""
    ')

    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        log_error "未在仓库 $GITHUB_REPO 中找到适用于架构 [$ARCH] 的 BBRv3 内核安装包。"
        log_info "提示: 如果您已自建仓库，请确认 GitHub Actions 是否已成功编译发布 Release。"
        return 1
    fi

    log_info "匹配到最新内核版本标签: ${GREEN}$latest_tag${PLAIN}"

    local asset_urls
    asset_urls=$(echo "$release_data" | jq -r --arg tag "$latest_tag" '
      .[] | select(.tag_name == $tag) | .assets[].browser_download_url
      | select(test("(-dbg_|-dbgsym_)"; "i") | not)
    ')

    local workdir="/tmp/bbr_kernel_install"
    rm -rf "$workdir" && mkdir -p "$workdir"

    for url in $asset_urls; do
        log_info "正在下载: $url"
        wget -q --show-progress "$url" -P "$workdir" || { log_error "下载失败: $url"; rm -rf "$workdir"; return 1; }
    done

    # 验证 deb 包完整性
    for deb in "$workdir"/linux-*.deb; do
        if ! dpkg-deb -I "$deb" >/dev/null 2>&1; then
            log_error "安装包损坏或 dpkg 无法读取: $deb"
            rm -rf "$workdir"
            return 1
        fi
    done

    log_info "正在安全安装新内核 (保留旧内核作为救援保底)..."
    if sudo dpkg -i "$workdir"/linux-*.deb; then
        log_info "正在更新 GRUB 引导记录..."
        if command -v update-grub &>/dev/null; then
            sudo update-grub
        fi
        log_success "新内核安装并更新引导成功！"
        rm -rf "$workdir"

        read -p "新内核需要重启系统才能生效，是否立即重启？(y/n): " do_reboot
        if [[ "$do_reboot" == "y" || "$do_reboot" == "Y" ]]; then
            log_info "系统正在重启..."
            sudo reboot
        else
            log_warn "请记得稍后手动执行 reboot 重启系统。"
        fi
    else
        log_error "内核安装失败！系统原有内核完整保留未受破坏，请勿重启并检查报错日志。"
        rm -rf "$workdir"
        return 1
    fi
}

# ==============================================================================
#  主菜单与交互调度
# ==============================================================================
show_menu() {
    clear
    local cur_algo
    local cur_qdisc
    local cur_mem
    cur_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    cur_mem=$(awk '/MemTotal:/ {print int($2/1024) "MB"}' /proc/meminfo 2>/dev/null || echo "未知")

    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "${GREEN}${BOLD}           bbr-v3-pro: Linux 双栈网络调优与 BBR 管理系统          ${PLAIN}"
    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "  1. 查看系统网络栈与内核状态 (含 BBRv3 检测)"
    echo -e "  2. 启用系统原生 BBR + FQ (官方内核 / 稳定零风险)"
    echo -e "  3. 启用系统原生 BBR + CAKE (抗 Bufferbloat 缓冲膨胀)"
    echo -e "  4. 应用 AI 网关与跨洋全栈优化 (TCP+UDP复合 / cliproxyapi + Hy2)"
    echo -e "  5. 应用亚太短链路低延迟调优 (精准小缓冲区)"
    echo -e "  6. 检查系统 TCP / UDP 端口占用 (协同排查 80/443/8443)"
    echo -e "  7. 还原系统出厂网络设置 (彻底清空调优配置)"
    echo -e "  8. 安装 / 更新 BBRv3 内核 (自建/个人 Release)"
    echo -e "  9. 创建 / 移除全局快捷命令 (bbr-pro)"
    echo -e "  0. 退出管理系统"
    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "当前状态: 拥塞 [${GREEN}${cur_algo}${PLAIN}] | 队列 [${GREEN}${cur_qdisc}${PLAIN}] | 物理内存 [${GREEN}${cur_mem}${PLAIN}]"
    echo -e "----------------------------------------------------------------"
    read -p "请输入功能编号 [0-9]: " opt

    case "$opt" in
        1) check_bbr_status ;;
        2) apply_bbr_and_qdisc "bbr" "fq" ;;
        3) apply_bbr_and_qdisc "bbr" "cake" ;;
        4) apply_ai_gateway_tuning ;;
        5) apply_apac_tuning ;;
        6) check_port_conflicts ;;
        7) clear_network_tuning ;;
        8) install_bbrv3_kernel "standard" ;;
        9)
            if [ -f "$QUICK_COMMAND_PATH" ]; then
                sudo rm -f "$QUICK_COMMAND_PATH"
                log_success "已移除快捷命令: $QUICK_COMMAND_PATH"
            else
                setup_shortcut
            fi
            ;;
        0) exit 0 ;;
        *) log_error "输入无效，请输入 [0-9]！" ;;
    esac

    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    show_menu
}

# ==============================================================================
#  主入口: CLI 自动化参数解析与调度
# ==============================================================================
check_and_install_deps

if [[ $# -gt 0 ]]; then
    case "$1" in
        --status)
            check_bbr_status
            exit 0
            ;;
        --apply-bbr)
            apply_bbr_and_qdisc "bbr" "fq"
            exit 0
            ;;
        --tune=ai-gateway|--apply-ai)
            apply_ai_gateway_tuning
            exit 0
            ;;
        --tune=apac)
            apply_apac_tuning
            exit 0
            ;;
        --clean)
            clear_network_tuning
            exit 0
            ;;
        --check-ports)
            check_port_conflicts
            exit 0
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "  --status              查看当前网络状态与内核版本"
            echo "  --apply-bbr           启用系统原生 BBR + FQ"
            echo "  --tune=ai-gateway     应用 AI 网关与跨洋全栈优化 (TCP+UDP)"
            echo "  --tune=apac           应用亚太短链路优化"
            echo "  --clean               清空所有调优配置恢复出厂默认"
            echo "  --check-ports         检查关键端口占用状态"
            exit 0
            ;;
        *)
            log_error "未知参数: $1 (使用 --help 查看参数列表)"
            exit 1
            ;;
    esac
fi

show_menu
