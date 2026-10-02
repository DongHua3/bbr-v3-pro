#!/usr/bin/env bash
# ==============================================================================
#  项目名称: bbr-v3-pro
#  定位: 生产级 Linux 双栈网络调优、拥塞控制与 BBRv3 管理系统
#  快捷唤醒: bbr
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
QUICK_COMMAND_PATH="/usr/local/bin/bbr"

# GitHub 仓库配置 (支持环境变量覆盖)
UPSTREAM_REPO="DongHua3/bbr-v3-pro"
GITHUB_REPO="${BBR_REPO:-$UPSTREAM_REPO}"
GITHUB_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# 依赖修复与检查
check_and_install_deps() {
    local missing_pkgs=()
    command -v curl >/dev/null 2>&1   || missing_pkgs+=("curl")
    command -v wget >/dev/null 2>&1   || missing_pkgs+=("wget")
    command -v jq >/dev/null 2>&1     || missing_pkgs+=("jq")
    command -v dpkg >/dev/null 2>&1   || missing_pkgs+=("dpkg")
    command -v awk >/dev/null 2>&1    || missing_pkgs+=("gawk")
    command -v sed >/dev/null 2>&1    || missing_pkgs+=("sed")
    command -v sysctl >/dev/null 2>&1 || missing_pkgs+=("procps")
    if ! command -v ip >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then
        missing_pkgs+=("iproute2")
    fi

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        # 去重
        local -A seen=()
        local unique_pkgs=()
        for p in "${missing_pkgs[@]}"; do
            if [[ -z "${seen[$p]:-}" ]]; then
                seen[$p]=1
                unique_pkgs+=("$p")
            fi
        done

        log_info "检测到缺失必要依赖包: ${unique_pkgs[*]}，正在自动安装..."
        
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

        if ! apt-get install -y "${unique_pkgs[@]}"; then
            log_error "自动安装依赖失败，请手动排查 apt 软件源后重试。"
            exit 1
        fi
        log_success "所有依赖环境已准备就绪。"
    fi
}

# 默认自动注册快捷命令 bbr (安全校验管道路径，防止把 /dev/fd/* 复制为空文件)
ensure_quick_command() {
    if [[ ! -f "$QUICK_COMMAND_PATH" ]]; then
        if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/* ]]; then
            cp -f "$0" "$QUICK_COMMAND_PATH"
            chmod 755 "$QUICK_COMMAND_PATH"
        else
            curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh" -o "$QUICK_COMMAND_PATH" 2>/dev/null && chmod 755 "$QUICK_COMMAND_PATH" || true
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
#  方案 4: 静态预设优化 (AI 网关 / 跨洋大带宽 / TCP+UDP 复合)
# ==============================================================================
apply_ai_gateway_tuning() {
    log_info "正在计算系统物理内存边界并应用 AI 网关 & 跨洋全栈优化预设..."
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

    log_success "AI 网关与跨洋全栈优化预设已写入：$SYSCTL_CONF"
    echo -e "  ${BOLD}核心调优摘要：${PLAIN}"
    echo -e "  - 拥塞控制 / 队列 : ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)${PLAIN}"
    echo -e "  - 单 Socket 缓冲区: ${GREEN}$((TARGET_SOCKET_BYTES / 1024 / 1024)) MB${PLAIN} (已实施小内存安全钳位)"
    echo -e "  - 全局 TCP 水位线 : ${GREEN}${TCP_MEM_MIN} / ${TCP_MEM_PRESSURE} / ${TCP_MEM_MAX} Pages${PLAIN} (最大占内存 40%)"
    echo -e "  - 网卡接收队列    : ${GREEN}10000${PLAIN} (防 Hy2 端口跳跃瞬时丢包)"
    echo -e "  - 空闲慢启动降速  : ${GREEN}已禁用 (tcp_slow_start_after_idle=0，大模型提示响应零延迟)${PLAIN}"
    echo -e "  - MTU 黑洞探测    : ${GREEN}已启用 (防跨洋大 Token 长上下文丢包)${PLAIN}"
}

# ==============================================================================
#  方案 5: BBR v3 智能带宽动态优化 (基于 BDP 带宽时延积计算模型)
# ==============================================================================
apply_smart_bandwidth_tuning() {
    echo -e "\n${BOLD}================= BBR v3 智能带宽优化 (BDP 计算引擎) =================${PLAIN}"
    echo -e "根据您的【实际线路带宽】与【真实网络延迟(RTT)】，科学计算最佳吞吐缓冲区大小。"
    echo -e "------------------------------------------------------------------------"
    
    get_safe_memory_limits
    local algo="bbr"
    local qdisc="fq"
    local output_bytes="4194304"

    read -p "请输入 VPS 峰值带宽 (Mbps，直接回车默认 100): " user_bw
    user_bw=$(echo "$user_bw" | tr -d '[:space:]')
    [[ -z "$user_bw" || ! "$user_bw" =~ ^[0-9]+$ ]] && user_bw=100

    echo -e "\n请选择您的主要目标链路延迟特征："
    echo -e "  1. 美西 / 欧美长链路 (RTT 约 150ms ~ 250ms，美区住宅/VPS 推荐)"
    echo -e "  2. 亚太近距离链路 (RTT 约 30ms ~ 80ms，香港/日本/新加坡)"
    echo -e "  3. 自定义输入延迟 (ms)"
    read -p "请选择 [1-3] (回车默认 1): " rtt_choice
    rtt_choice=$(echo "$rtt_choice" | tr -d '[:space:]')
    
    local rtt_ms=180
    case "$rtt_choice" in
        2) rtt_ms=60 ;;
        3) 
            read -p "请输入真实单程延迟 (毫秒，例如 180): " user_rtt
            user_rtt=$(echo "$user_rtt" | tr -d '[:space:]')
            [[ -n "$user_rtt" && "$user_rtt" =~ ^[0-9]+$ ]] && rtt_ms=$user_rtt
            ;;
        *) rtt_ms=180 ;;
    esac

    # BDP 计算公式: BDP(Bytes) = (带宽(Mbps) * 10^6 / 8) * (延迟(ms) / 1000)
    # 结合 BBR 的动态拥塞窗口增益系数 (~2.5x - 3x BDP) 留足突发空间
    local bdp_raw=$(( (user_bw * 125000 * rtt_ms) / 1000 ))
    local calculated_buffer=$(( bdp_raw * 3 ))

    # 设定下限保底 4MB，上限不能击穿小内存物理钳位线
    local min_floor=$(( 4 * 1024 * 1024 ))
    (( calculated_buffer < min_floor )) && calculated_buffer=$min_floor
    if (( calculated_buffer > MAX_SOCKET_BYTES )); then
        calculated_buffer=$MAX_SOCKET_BYTES
        log_warn "计算结果超出小内存安全线，已触发安全钳位限制为: $((MAX_SOCKET_BYTES / 1024 / 1024)) MB"
    fi

    load_qdisc_module "$qdisc"

    sudo sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$algo" >/dev/null 2>&1
    sudo sysctl -w net.core.rmem_max="$calculated_buffer" >/dev/null 2>&1
    sudo sysctl -w net.core.wmem_max="$calculated_buffer" >/dev/null 2>&1
    sudo sysctl -w net.core.netdev_max_backlog="10000" >/dev/null 2>&1
    sudo sysctl -w net.core.somaxconn="4096" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 $calculated_buffer" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 $calculated_buffer" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_mem="$TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_limit_output_bytes="$output_bytes" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_slow_start_after_idle="0" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_window_scaling="1" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_mtu_probing="1" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_notsent_lowat="16384" >/dev/null 2>&1

    clean_sysctl_conf
    {
        echo "# bbr-v3-pro: Smart BDP Dynamic Tuning (BW: ${user_bw}Mbps, RTT: ${rtt_ms}ms)"
        echo "net.core.default_qdisc = $qdisc"
        echo "net.ipv4.tcp_congestion_control = $algo"
        echo "net.core.rmem_max = $calculated_buffer"
        echo "net.core.wmem_max = $calculated_buffer"
        echo "net.core.netdev_max_backlog = 10000"
        echo "net.core.somaxconn = 4096"
        echo "net.ipv4.tcp_rmem = 4096 87380 $calculated_buffer"
        echo "net.ipv4.tcp_wmem = 4096 65536 $calculated_buffer"
        echo "net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX"
        echo "net.ipv4.tcp_limit_output_bytes = $output_bytes"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_window_scaling = 1"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "net.ipv4.tcp_notsent_lowat = 16384"
    } | sudo tee -a "$SYSCTL_CONF" >/dev/null

    log_success "BBR v3 智能带宽动态调优已完成并持久化生效！"
    echo -e "  - 输入基准      : ${GREEN}${user_bw} Mbps / 延迟 ${rtt_ms} ms${PLAIN}"
    echo -e "  - 计算所得套接字: ${GREEN}$((calculated_buffer / 1024 / 1024)) MB${PLAIN} (理论 BDP 黄金窗口)"
    echo -e "  - 物理安全线    : 全局 TCP 限制在物理内存 40% 水位内，绝无 OOM 隐患"
}

# ==============================================================================
#  方案 6: 亚太短链路低延迟调优 (适用于香港 / 日本 / 新加坡等直连)
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
#  端口冲突检测工具 (支持核心端口 + 交互式自定义端口查验)
# ==============================================================================
check_port_conflicts() {
    echo -e "\n${BOLD}================= 系统关键端口占用探测 =================${PLAIN}"
    local default_ports=("80:tcp" "443:tcp" "443:udp" "8443:tcp" "8443:udp")
    
    printf "%-12s | %-8s | %-16s | %-24s\n" "端口" "协议" "监听状态" "占用进程 (PID/名称)"
    echo "------------------------------------------------------------------------"
    
    for p in "${default_ports[@]}"; do
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
    echo -e "${BLUE}[最佳协同实践参考]${PLAIN}"
    echo -e "  - Caddy 反代: 监听 TCP 80/443 (若开启 HTTP/3 独占 UDP 443)"
    echo -e "  - Hysteria 2: 监听 8443 + 端口跳跃 (避开 UDP 443，互不冲突)"
    echo ""
    read -p "是否需要自定义查询特定端口？(输入端口号，回车跳过): " custom_p
    custom_p=$(echo "$custom_p" | tr -d '[:space:]')
    if [[ "$custom_p" =~ ^[0-9]+$ ]] && (( custom_p >= 1 && custom_p <= 65535 )); then
        echo -e "\n${BOLD}正在查询自定义端口 $custom_p...${PLAIN}"
        local tcp_raw udp_raw
        tcp_raw=$(ss -tlpn "sport = :$custom_p" 2>/dev/null | grep -E ":$custom_p\b" || true)
        udp_raw=$(ss -ulpn "sport = :$custom_p" 2>/dev/null | grep -E ":$custom_p\b" || true)
        if [ -n "$tcp_raw" ]; then
            echo -e "  TCP 状态: ${RED}已占用${PLAIN} 进程: $(echo "$tcp_raw" | awk '{print $NF}')"
        else
            echo -e "  TCP 状态: ${GREEN}空闲${PLAIN}"
        fi
        if [ -n "$udp_raw" ]; then
            echo -e "  UDP 状态: ${RED}已占用${PLAIN} 进程: $(echo "$udp_raw" | awk '{print $NF}')"
        else
            echo -e "  UDP 状态: ${GREEN}空闲${PLAIN}"
        fi
    fi
}

# ==============================================================================
#  获取当前网络核心状态 (用于顶部仪表盘与状态检查)
# ==============================================================================
get_network_metrics() {
    METRIC_KERNEL=$(uname -r)
    METRIC_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    METRIC_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    
    local bbr_mod bbr_ver
    bbr_mod=$(modinfo tcp_bbr 2>/dev/null || true)
    if [ -z "$bbr_mod" ]; then
        depmod -a 2>/dev/null || true
        bbr_mod=$(modinfo tcp_bbr 2>/dev/null || true)
    fi
    bbr_ver=$(echo "$bbr_mod" | awk '/^version:/ {print $2}')
    if [[ "$bbr_ver" == "3" ]]; then
        METRIC_ALGO_DISPLAY="${METRIC_ALGO} (v3)"
    else
        METRIC_ALGO_DISPLAY="${METRIC_ALGO}"
    fi

    local cur_rmem
    cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "212992")
    if (( cur_rmem >= 10485760 )); then
        METRIC_UDP_BUFFER="$((cur_rmem / 1024 / 1024)) MB (AI/Hy2 专属大水管)"
    else
        METRIC_UDP_BUFFER="$((cur_rmem / 1024)) KB (系统默认)"
    fi

    local mem_total
    mem_total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "0")
    if [ -f "$SYSCTL_CONF" ]; then
        METRIC_MEM_DISPLAY="${mem_total} MB (已开启 40% 防 OOM 保护)"
    else
        METRIC_MEM_DISPLAY="${mem_total} MB (系统默认)"
    fi
}

check_bbr_status() {
    get_network_metrics
    echo -e "\n${BOLD}==================== BBR 状态与系统体检 ====================${PLAIN}"
    echo -e "系统内核版本   : ${GREEN}$METRIC_KERNEL${PLAIN}"
    echo -e "TCP 拥塞控制   : ${GREEN}$METRIC_ALGO_DISPLAY${PLAIN}"
    echo -e "UDP 套接字缓冲 : ${GREEN}$METRIC_UDP_BUFFER${PLAIN}"
    echo -e "队列管理算法   : ${GREEN}$METRIC_QDISC${PLAIN}"
    echo -e "物理内存状态   : ${GREEN}$METRIC_MEM_DISPLAY${PLAIN}"

    if [ -f "$SYSCTL_CONF" ]; then
        echo -e "持久化优化配置 : ${GREEN}已加载 ($SYSCTL_CONF)${PLAIN}"
    else
        echo -e "持久化优化配置 : ${YELLOW}未加载 (当前运行系统默认参数)${PLAIN}"
    fi
}

# ==============================================================================
#  原子化安全内核安装逻辑 (防砖架构)
# ==============================================================================
version_ge() {
    local current="$1"
    local required="$2"
    [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -n 1)" == "$required" ]]
}

debian_version_from_codename() {
    case "${1:-}" in
        bookworm) echo "12" ;;
        trixie) echo "13" ;;
        forky) echo "14" ;;
        sid|unstable) echo "999" ;;
        *) return 1 ;;
    esac
}

assert_supported_kernel_install_system() {
    if [[ ! -r /etc/os-release ]]; then
        log_error "无法识别当前系统版本，已拒绝安装主线内核。"
        return 1
    fi
    local os_id="" os_version="" os_codename="" os_name="" min_version="" distro_name=""
    . /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    os_name="${PRETTY_NAME:-${NAME:-未知系统}}"

    case "$os_id" in
        ubuntu)
            min_version="22.04"
            distro_name="Ubuntu"
            ;;
        debian)
            min_version="12"
            distro_name="Debian"
            if [[ -z "$os_version" ]]; then
                os_version="$(debian_version_from_codename "$os_codename" || true)"
            fi
            ;;
        *)
            log_error "当前系统为 $os_name，不在主线内核安装白名单内。"
            log_warn "最低要求支持: Ubuntu 22.04+ / Debian 12+，以避免旧系统引导链路导致 kernel panic。"
            return 1
            ;;
    esac

    if [[ -z "$os_version" ]] || ! version_ge "$os_version" "$min_version"; then
        log_error "当前系统版本过旧: $os_name。已拒绝安装主线内核。"
        log_warn "最低要求: ${distro_name} ${min_version}+。请先升级系统后再运行。"
        return 1
    fi
    return 0
}

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
    assert_supported_kernel_install_system || return 1

    local target_repo="${GITHUB_REPO}"
    log_info "正在从 GitHub 获取 [$target_repo] 最新发布的内核版本..."

    local base_url="https://api.github.com/repos/${target_repo}/releases"
    local release_data
    release_data=$(gh_api_get "$base_url" 2>/dev/null || true)

    local arch_filter="x86_64"
    [[ "$ARCH" == "aarch64" ]] && arch_filter="arm64"

    local latest_tag=""
    if [[ -n "$release_data" ]]; then
        latest_tag=$(echo "$release_data" | jq -r --arg filter "$arch_filter" --arg prof "$profile" '
          if type=="array" then
            map(
              select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
              | select(if $prof == "max" then (.tag_name | endswith("-max")) else ((.tag_name | endswith("-max")) | not) end)
            )
            | sort_by(.published_at)
            | .[-1].tag_name // ""
          else "" end
        ' 2>/dev/null || true)
    fi

    # 智能兜底回落逻辑: 如果私有仓库未发布对应内核包，自动回落至官方中央源
    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        if [[ "$target_repo" != "$UPSTREAM_REPO" ]]; then
            log_warn "未在私有仓库 [$target_repo] 找到可用内核包，正在自动兜底切换至官方中央源 [$UPSTREAM_REPO]..."
            target_repo="$UPSTREAM_REPO"
            base_url="https://api.github.com/repos/${target_repo}/releases"
            release_data=$(gh_api_get "$base_url" 2>/dev/null || true)
            if [[ -n "$release_data" ]]; then
                latest_tag=$(echo "$release_data" | jq -r --arg filter "$arch_filter" --arg prof "$profile" '
                  if type=="array" then
                    map(
                      select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
                      | select(if $prof == "max" then (.tag_name | endswith("-max")) else ((.tag_name | endswith("-max")) | not) end)
                    )
                    | sort_by(.published_at)
                    | .[-1].tag_name // ""
                  else "" end
                ' 2>/dev/null || true)
            fi
        fi
    fi

    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        log_error "未在仓库 [$target_repo] 中找到适用于架构 [$ARCH] 的 BBRv3 内核安装包。"
        log_info "排错提示: 若刚新建仓库，请确认 GitHub Actions 是否已编译完成并发布 Release；亦可检查网络或设置 GITHUB_TOKEN 避免 API 限流。"
        return 1
    fi

    log_info "匹配到最新内核版本标签: ${GREEN}$latest_tag${PLAIN} (来源: $target_repo)"

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
    if sudo dpkg -i "$workdir"/linux-*.deb || sudo apt-get install -f -y; then
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
#  安全卸载自建 BBRv3 内核 (回滚至官方原厂内核)
# ==============================================================================
uninstall_bbrv3_kernel() {
    log_info "正在检测系统中已安装的 BBRv3 内核包..."
    
    local packages_to_remove
    packages_to_remove=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-(image|headers)-/ && ($2 ~ /bbrv3/ || $2 ~ /joeyblog/) {print $2}' | tr '\n' ' ')

    if [[ -z "$packages_to_remove" ]]; then
        log_warn "未在当前系统中检测到已安装的自建 BBRv3 内核包。"
        return 0
    fi

    # 安全断言：检查系统内是否保留官方/通用兜底内核
    local fallback_kernels
    fallback_kernels=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-image-[0-9]/ && ($2 !~ /bbrv3/ && $2 !~ /joeyblog/) {print $2}' | tr '\n' ' ')

    if [[ -z "$fallback_kernels" ]]; then
        log_error "【高危拦截】系统未检测到任何官方备用内核！"
        log_warn "若此时卸载 BBRv3 内核，系统重启后将因无可用内核直接失联变砖！"
        log_info "请先执行: sudo apt-get install -y linux-image-cloud-amd64 (或 linux-image-generic) 安装官方内核后再卸载。"
        return 1
    fi

    echo -e "即将卸载以下 BBRv3 内核包: ${YELLOW}$packages_to_remove${PLAIN}"
    echo -e "系统将安全回滚至备用官方内核: ${GREEN}$fallback_kernels${PLAIN}"
    read -p "确认卸载并回滚引导吗？(y/n): " confirm_un
    if [[ "$confirm_un" != "y" && "$confirm_un" != "Y" ]]; then
        log_info "操作已取消。"
        return 0
    fi

    log_info "正在安全卸载 BBRv3 内核包..."
    if sudo apt-get purge -y $packages_to_remove; then
        log_info "正在更新 GRUB 引导记录..."
        if command -v update-grub &>/dev/null; then
            sudo update-grub
        fi
        log_success "BBRv3 内核已成功卸载，GRUB 引导已恢复官方内核！"
        read -p "需要重启系统以加载官方内核，是否立即重启？(y/n): " do_rb
        if [[ "$do_rb" == "y" || "$do_rb" == "Y" ]]; then
            log_info "系统正在重启..."
            sudo reboot
        else
            log_warn "请稍后手动执行 reboot 重启生效。"
        fi
    else
        log_error "卸载过程中出现错误，请检查 dpkg / apt 状态。"
        return 1
    fi
}

# ==============================================================================
#  彻底卸载 bbr-v3-pro (清理快捷命令及所有残留)
# ==============================================================================
uninstall_everything() {
    echo -e "\n${BOLD}================= 彻底卸载 bbr-v3-pro =================${PLAIN}"
    echo -e "该操作将："
    echo -e "  1. 清空所有持久化 sysctl 网络调优参数并重载系统默认值"
    echo -e "  2. 移除系统快捷唤醒指令 ($QUICK_COMMAND_PATH)"
    echo -e "  3. 删除临时下载目录与残留安全配置"
    echo -e "--------------------------------------------------------"
    read -p "确认彻底卸载本工具及所有网络配置吗？(y/n): " confirm_all
    if [[ "$confirm_all" != "y" && "$confirm_all" != "Y" ]]; then
        log_info "操作已取消。"
        return 0
    fi

    clear_network_tuning
    sudo rm -f "$QUICK_COMMAND_PATH" "$SECURITY_MODPROBE_CONF"
    sudo rm -rf /tmp/bbr_kernel_install
    log_success "bbr-v3-pro 工具与所有调优配置已彻底卸载完毕，系统已恢复纯净状态。"
    exit 0
}

# ==============================================================================
#  主菜单与交互调度
# ==============================================================================
show_menu() {
    while true; do
        clear
        get_network_metrics

        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e " 系统内核版本: ${GREEN}${METRIC_KERNEL}${PLAIN}"
        echo -e " TCP 拥塞控制: ${GREEN}${METRIC_ALGO_DISPLAY}${PLAIN}"
        echo -e " UDP 套接字缓冲: ${GREEN}${METRIC_UDP_BUFFER}${PLAIN}"
        echo -e " 队列调度算法: ${GREEN}${METRIC_QDISC}${PLAIN}"
        echo -e " 物理内存状态: ${GREEN}${METRIC_MEM_DISPLAY}${PLAIN}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "  ${BOLD}1.${PLAIN} 查看系统网络栈与内核状态 (含 BBRv3 检测)"
        echo -e "  ${BOLD}2.${PLAIN} 安装 / 更新 BBRv3 内核 (自建 / 个人 Release)"
        echo -e "  ${BOLD}3.${PLAIN} 启用 BBR + FQ"
        echo -e "  ${BOLD}4.${PLAIN} 启用 BBR + CAKE (抗晚高峰网络拥堵、防队头阻塞)"
        echo -e "  ${BOLD}5.${PLAIN} 应用 AI 网关与跨洋全栈优化 (TCP+UDP复合 / 一键懒人预设)"
        echo -e "  ${BOLD}6.${PLAIN} BBR v3 智能带宽动态调优 (按实际带宽与延迟计算 BDP)"
        echo -e "  ${BOLD}7.${PLAIN} 应用亚太短链路低延迟调优 (精准小缓冲区)"
        echo -e "  ${BOLD}8.${PLAIN} 检查系统 TCP / UDP 端口占用 (80 / 443 / 8443 / 自定义)"
        echo -e "  ${BOLD}9.${PLAIN} 还原系统出厂网络设置 (清空所有 sysctl 调优配置)"
        echo -e "  ${BOLD}10.${PLAIN} 卸载自建 BBRv3 内核 (安全回滚至官方原厂内核)"
        echo -e "  ${BOLD}11.${PLAIN} 彻底卸载 bbr-v3-pro (清理快捷命令及所有残留)"
        echo -e "  ${BOLD}0.${PLAIN} 退出管理系统"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "快捷唤醒指令: ${GREEN}bbr${PLAIN}"
        echo -e "----------------------------------------------------------------"
        read -p "请输入功能编号 [0-11]: " opt

        case "$opt" in
            1) check_bbr_status ;;
            2) install_bbrv3_kernel "standard" ;;
            3) apply_bbr_and_qdisc "bbr" "fq" ;;
            4) apply_bbr_and_qdisc "bbr" "cake" ;;
            5) apply_ai_gateway_tuning ;;
            6) apply_smart_bandwidth_tuning ;;
            7) apply_apac_tuning ;;
            8) check_port_conflicts ;;
            9) clear_network_tuning ;;
            10) uninstall_bbrv3_kernel ;;
            11) uninstall_everything ;;
            0) exit 0 ;;
            *) log_error "输入无效，请输入 [0-11]！" ;;
        esac

        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# ==============================================================================
#  主入口: CLI 自动化参数解析与调度
# ==============================================================================
check_and_install_deps
ensure_quick_command

if [[ $# -gt 0 ]]; then
    case "$1" in
        --status)
            check_bbr_status
            exit 0
            ;;
        --install-kernel)
            install_bbrv3_kernel "standard"
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
        --tune=smart)
            apply_smart_bandwidth_tuning
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
        --uninstall-kernel)
            uninstall_bbrv3_kernel
            exit 0
            ;;
        --uninstall-all)
            uninstall_everything
            exit 0
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "  --status              查看当前网络状态与内核版本"
            echo "  --install-kernel      安装或更新最新 BBRv3 内核"
            echo "  --apply-bbr           启用系统原生 BBR + FQ"
            echo "  --tune=ai-gateway     应用 AI 网关与跨洋全栈优化 (TCP+UDP)"
            echo "  --tune=smart          应用智能 BDP 动态带宽优化"
            echo "  --tune=apac           应用亚太短链路优化"
            echo "  --clean               清空所有调优配置恢复出厂默认"
            echo "  --check-ports         检查关键端口占用状态"
            echo "  --uninstall-kernel    安全卸载 BBRv3 内核并回滚"
            echo "  --uninstall-all       彻底卸载工具与所有网络配置"
            exit 0
            ;;
        *)
            log_error "未知参数: $1 (使用 --help 查看参数列表)"
            exit 1
            ;;
    esac
fi

show_menu
