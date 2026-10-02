#!/usr/bin/env bash
# ==============================================================================
#  项目名称: bbr-v3-pro
#  定位: 生产级 Linux 双栈网络调优、拥塞控制与 BBRv3 管理系统
#  快捷唤醒: bbr
#  特点: 纯净无广告、无 Emoji、TCP+UDP 双栈优化、小内存防 OOM 钳位、原子化安全防砖
# ==============================================================================

set -u

# 脚本版本。改动本脚本时请一并递增，便于判断本地副本（如 /usr/local/bin/bbr
# 的缓存）是否已过期。用 `--version` 或 `--status` 查看。
#
# 版本规则（语义化版本）：
#   主版本 不兼容变更（配置文件路径、CLI 参数语义、菜单编号调整）
#   次版本 新增功能（新调优预设、新 CLI 参数、新检查项）
#   修订号 缺陷修复、文案与显示修正
BBR_SCRIPT_VERSION="2.0.0"

# GitHub 仓库配置 (支持环境变量覆盖)
UPSTREAM_REPO="DongHua3/bbr-v3-pro"
GITHUB_REPO="${GITHUB_REPO:-${BBR_REPO:-$UPSTREAM_REPO}}"

# ==============================================================================
#  自更新：把快捷命令更新到最新版
#  返回 0=成功/已最新，1=失败或被拒绝
#
#  注意：本函数定义在脚本顶部，因为 --update 参数分支在 root 与发行版检查
#  之前就要用到它（更新自身不应依赖被更新的环境）。
#  仓库配置已在上方提前初始化，目标路径使用字面路径（不依赖稍后定义的 QUICK_COMMAND_PATH）。
# ==============================================================================
self_update() {
    local force="${1:-0}"
    local target="/usr/local/bin/bbr"
    local repo="${GITHUB_REPO:-$UPSTREAM_REPO}"
    local url="https://raw.githubusercontent.com/${repo}/main/install.sh"
    local tmp new tver
    echo "当前版本: v$BBR_SCRIPT_VERSION"
    echo "正在获取最新版..."

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "[ERROR] 需要 curl 或 wget 才能更新。" >&2
        return 1
    fi

    tmp="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$tmp" "$url" \
            || { echo "[ERROR] 下载失败，请检查网络。" >&2; rm -f "$tmp"; return 1; }
    else
        wget -q -O "$tmp" "$url" \
            || { echo "[ERROR] 下载失败，请检查网络。" >&2; rm -f "$tmp"; return 1; }
    fi

    # 校验下载到的确实是本项目脚本，避免把坏文件写进 PATH
    if ! grep -q 'QUICK_COMMAND_PATH=' "$tmp" 2>/dev/null; then
        echo "[ERROR] 下载内容校验失败（不是本项目脚本），已放弃更新。" >&2
        rm -f "$tmp"; return 1
    fi

    new="$(grep -m1 '^BBR_SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)"
    if [[ -z "$new" ]]; then
        echo "[ERROR] 无法识别新版本号，已放弃更新。" >&2
        rm -f "$tmp"; return 1
    fi

    # 版本比较：raw.githubusercontent.com 的边缘缓存不尊重 Cache-Control，
    # 刚推送后可能仍返回旧版本。不区分"相同"与"更旧"会让用户误判。
    if [[ "$new" == "$BBR_SCRIPT_VERSION" ]]; then
        if (( force )); then
            echo "远端与本地同为 v$new，已指定强制覆盖，继续写入。"
        else
            echo "已是最新版本 v$new，无需更新。"
            echo "（若确认远端已发布更新版，可能是 raw CDN 缓存未刷新，"
            echo "  可等待几分钟后重试；或执行：$0 --update --force）"
            rm -f "$tmp"
            return 0
        fi
    fi

    if (( force == 0 )) && [[ "$new" != "$BBR_SCRIPT_VERSION" ]] \
        && ! printf '%s\n%s\n' "$BBR_SCRIPT_VERSION" "$new" | sort -V -C; then
        echo "[WARN] 远端版本 v$new 低于本地 v$BBR_SCRIPT_VERSION，" >&2
        echo "       通常是 raw CDN 缓存尚未刷新，本次不做覆盖以免降级。" >&2
        echo "       如确认要强制覆盖：$0 --update --force" >&2
        rm -f "$tmp"
        return 1
    fi

    if [[ $EUID -ne 0 ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "[ERROR] 需要 root 权限写入 $target（且系统无 sudo）。" >&2
            rm -f "$tmp"; return 1
        fi
        sudo cp "$tmp" "$target" && sudo chmod 755 "$target" \
            || { echo "[ERROR] 写入 $target 失败。" >&2; rm -f "$tmp"; return 1; }
    else
        cp "$tmp" "$target" && chmod 755 "$target" \
            || { echo "[ERROR] 写入 $target 失败。" >&2; rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"

    echo "[OK] 已更新: v$BBR_SCRIPT_VERSION -> v$new  ($target)"
    return 0
}

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

# 以 root 运行时不需要 sudo。精简镜像/容器里常常没有安装 sudo，
# 此时 `sudo xxx` 会以 "command not found" 失败，导致所有 sysctl 写入、
# modprobe、模块探测被误判为失败（明明权限足够）。
# 因此统一走 $SUDO：root 下为空，非 root 下为 sudo。
# 注意：必须在任何引用 $SUDO 的代码之前定义（set -u 下引用未定义变量会直接退出）。
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

show_help() {
    echo "bbr-v3-pro v$BBR_SCRIPT_VERSION"
    echo "用法: $0 [选项]"
    echo "  --version             查看脚本版本"
    echo "  --update [--force]    把快捷命令 bbr 更新到最新版（--force 强制覆盖）"
    echo "  --status              查看当前网络状态与内核版本"
    echo "  --install-kernel      安装/更新 BBRv3 内核"
    echo "  --apply-bbr           启用系统原生 BBR + FQ"
    echo "  --tune=ai-gateway     应用 AI 网关与跨洋全栈优化（推荐默认）"
    echo "  --tune=smart          应用智能 BDP 动态带宽优化"
    echo "  --tune=apac           应用亚太短链路低延迟优化"
    echo "  --check-ports         检查关键端口占用状态"
    echo "  --clean               清空所有调优配置恢复出厂默认"
    echo "  --mitigate-cve        应用 Dirty Frag 与 CVE-2026-31431 安全缓解 (写入黑名单并卸载高危模块)"
    echo "  --uninstall-kernel    安全卸载 BBRv3 内核并回滚引导"
    echo "  --uninstall-all       彻底卸载工具与所有网络配置"
    echo "  --help                查看此帮助信息"
}

# 信息类参数提前处理：不依赖 root 与发行版，非 Debian 或普通用户也能查
if [[ $# -gt 0 ]]; then
    case "$1" in
        --version|-V)
            echo "bbr-v3-pro v$BBR_SCRIPT_VERSION"
            exit 0
            ;;
        --update|--self-update)
            if [[ "${2:-}" == "--force" || "${2:-}" == "-f" ]]; then
                self_update 1
            else
                self_update 0
            fi
            exit $?
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac
fi

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
GITHUB_REPO="${GITHUB_REPO:-${BBR_REPO:-$UPSTREAM_REPO}}"
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
            # 某些第三方源（如 Caddy 官方源）在部分网络环境下会拖垮整个
            # apt-get update。这里临时【移开】这些源重试，随后立即恢复 ——
            # 绝不静默删除用户的软件源，那会让用户后续收不到该软件的安全更新。
            log_warn "apt-get update 出现错误，尝试临时移开第三方源后重试..."
            local caddy_backup="/tmp/bbr-apt-sources-backup.$$"
            mkdir -p "$caddy_backup"
            local moved=0 f
            for f in /etc/apt/sources.list.d/caddy*.list /etc/apt/sources.list.d/caddy*.sources; do
                [[ -f "$f" ]] || continue
                if mv "$f" "$caddy_backup/" 2>/dev/null; then
                    moved=$((moved + 1))
                fi
            done

            if (( moved > 0 )); then
                log_info "已临时移开 $moved 个第三方源文件，重试 apt-get update..."
            fi
            apt-get update || true

            # 无论如何都恢复：这些是用户的合法软件源
            if (( moved > 0 )); then
                local restore_failed=0
                for f in "$caddy_backup"/*; do
                    [[ -e "$f" ]] || continue
                    if ! mv -f "$f" /etc/apt/sources.list.d/ 2>/dev/null; then
                        restore_failed=$((restore_failed + 1))
                        log_error "未能恢复源文件: $(basename "$f")"
                    fi
                done
                if (( restore_failed > 0 )); then
                    log_warn "有 $restore_failed 个源文件未能自动恢复，备份保留在: $caddy_backup"
                    log_warn "请手工移动到 /etc/apt/sources.list.d/ 后执行 apt-get update。"
                else
                    rmdir "$caddy_backup" 2>/dev/null || true
                    log_info "已恢复被临时移开的第三方源文件。"
                fi
            fi
        fi

        if ! apt-get install -y "${unique_pkgs[@]}"; then
            log_error "自动安装依赖失败，请手动排查 apt 软件源后重试。"
            exit 1
        fi
        log_success "所有依赖环境已准备就绪。"
    fi
}

# 判断 $0 是否是一个可以安全复制成快捷命令的真实脚本文件。
# 反例：`sudo bash install.sh` 时 $0 是字面量 "bash"，而 bash 确实是 PATH 里的
# 一个可读文件，旧实现会直接把 /bin/bash 复制成 /usr/local/bin/bbr。
is_self_script_file() {
    local f="${1:-}"
    [[ -n "$f" ]] || return 1
    case "$f" in
        /dev/fd/*|/proc/*|bash|sh|dash|-bash|sudo) return 1 ;;
    esac

    # 规范化相对路径（如 ./install.sh）为绝对路径
    if [[ "$f" != /* ]]; then
        if command -v realpath >/dev/null 2>&1; then
            f="$(realpath "$f" 2>/dev/null || echo "$f")"
        elif command -v readlink >/dev/null 2>&1; then
            f="$(readlink -f "$f" 2>/dev/null || echo "$f")"
        elif [[ -e "$f" ]]; then
            f="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/$(basename "$f")"
        fi
    fi

    [[ "$f" == /* && -f "$f" && -r "$f" ]] || return 1
    head -n 1 "$f" 2>/dev/null | grep -Eq '^#!.*\b(bash|sh)\b' || return 1
    # 内容指纹：确认是本项目管理脚本，避免把无关脚本装成 bbr
    grep -q 'QUICK_COMMAND_PATH=' "$f" 2>/dev/null || return 1
    return 0
}

# 默认自动注册快捷命令 bbr (安全校验管道路径，防止把 /dev/fd/* 复制为空文件)
ensure_quick_command() {
    [[ -f "$QUICK_COMMAND_PATH" ]] && return 0

    # 函数内用 BASH_SOURCE 比 $0 可靠，退化到 $0
    local self="${BASH_SOURCE[0]:-$0}"
    if [[ -n "$self" && "$self" != /* ]]; then
        if command -v realpath >/dev/null 2>&1; then
            self="$(realpath "$self" 2>/dev/null || echo "$self")"
        elif command -v readlink >/dev/null 2>&1; then
            self="$(readlink -f "$self" 2>/dev/null || echo "$self")"
        elif [[ -e "$self" ]]; then
            self="$(cd "$(dirname "$self")" 2>/dev/null && pwd -P)/$(basename "$self")"
        fi
    fi

    if is_self_script_file "$self"; then
        if cp -f "$self" "$QUICK_COMMAND_PATH" && chmod 755 "$QUICK_COMMAND_PATH"; then
            return 0
        fi
    fi

    # 管道执行或文件名不可靠时走网络；失败不阻断主流程
    curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh" \
        -o "$QUICK_COMMAND_PATH" 2>/dev/null && chmod 755 "$QUICK_COMMAND_PATH" \
        || log_warn "快捷命令 $QUICK_COMMAND_PATH 安装失败，不影响本次运行。"
}

# ==============================================================================
#  安全缓解 (Dirty Frag / CVE-2026-31431 风险面收敛)
#  说明: 本项目的内核构建关闭了 IPsec ESP 与 RxRPC (CONFIG_XFRM_ESP /
#  CONFIG_INET_ESP / CONFIG_INET6_ESP / CONFIG_AF_RXRPC)，但 AEAD 用户态接口
#  (CONFIG_CRYPTO_USER_API_AEAD) 目前仍以模块形式编入，因此这里用 modprobe
#  黑名单做运行时收敛；同时清理旧版本脚本可能残留的 algif_aead 黑名单。
# ==============================================================================

# 当前运行内核是否已关闭 AEAD 用户态接口
current_kernel_disables_aead() {
    local kernel_release boot_config
    kernel_release=$(uname -r)
    boot_config="/boot/config-$kernel_release"

    if [[ -r "$boot_config" ]]; then
        grep -q '^# CONFIG_CRYPTO_USER_API_AEAD is not set' "$boot_config"
        return $?
    fi

    if [[ -r /proc/config.gz ]] && command -v gzip >/dev/null 2>&1; then
        gzip -dc /proc/config.gz 2>/dev/null \
            | grep -q '^# CONFIG_CRYPTO_USER_API_AEAD is not set'
        return $?
    fi

    return 1
}

# 幂等追加一条 modprobe 规则
ensure_security_rule() {
    local rule="$1"
    local changed_var="$2"
    if ! grep -Fqx "$rule" "$SECURITY_MODPROBE_CONF" 2>/dev/null; then
        echo "$rule" | $SUDO tee -a "$SECURITY_MODPROBE_CONF" >/dev/null
        eval "$changed_var=1"
    fi
}

apply_security_mitigations() {
    local unload_modules="${1:-0}"
    local changed=0 managed_marker="# Managed by bbr-v3-pro"

    $SUDO touch "$SECURITY_MODPROBE_CONF" 2>/dev/null || {
        log_warn "无法写入 $SECURITY_MODPROBE_CONF，跳过安全缓解。"
        return 0
    }

    if ! grep -Fqx "$managed_marker" "$SECURITY_MODPROBE_CONF" 2>/dev/null; then
        echo "$managed_marker" | $SUDO tee -a "$SECURITY_MODPROBE_CONF" >/dev/null
        changed=1
    fi

    # Dirty Frag 风险面: esp4 / esp6 / rxrpc
    ensure_security_rule "blacklist esp4" changed
    ensure_security_rule "install esp4 /bin/false" changed
    ensure_security_rule "blacklist esp6" changed
    ensure_security_rule "install esp6 /bin/false" changed
    ensure_security_rule "blacklist rxrpc" changed
    ensure_security_rule "install rxrpc /bin/false" changed

    # CVE-2026-31431: AEAD 用户态接口当前仍开启，写入 algif_aead 黑名单收敛；
    # 一旦内核配置侧关闭该接口（current_kernel_disables_aead 为真），
    # 则移除黑名单，避免留下无用规则掩盖真实配置状态。
    if current_kernel_disables_aead; then
        local removed=0
        if grep -Eq '^(blacklist algif_aead|install algif_aead /bin/false)$' "$SECURITY_MODPROBE_CONF" 2>/dev/null; then
            $SUDO sed -i '/^blacklist algif_aead$/d' "$SECURITY_MODPROBE_CONF"
            $SUDO sed -i '/^install algif_aead \/bin\/false$/d' "$SECURITY_MODPROBE_CONF"
            removed=1
            log_info "当前内核已关闭 CRYPTO_USER_API_AEAD，已移除多余的 algif_aead 黑名单。"
        fi
        (( removed )) && changed=1
    else
        ensure_security_rule "blacklist algif_aead" changed
        ensure_security_rule "install algif_aead /bin/false" changed
    fi

    # 已加载的模块仅在显式请求时卸载，避免菜单启动时打断已有 IPsec VPN 隧道
    if (( unload_modules )); then
        local mod
        for mod in esp4 esp6 rxrpc algif_aead; do
            if lsmod 2>/dev/null | grep -q "^${mod}"; then
                if $SUDO modprobe -r "$mod" 2>/dev/null; then
                    log_info "已卸载模块 $mod，当前会话缓解已生效。"
                else
                    log_warn "模块 $mod 正被占用，黑名单将在重启后生效。"
                fi
            fi
        done
    fi

    if (( changed )); then
        log_success "安全缓解规则已写入: $SECURITY_MODPROBE_CONF"
    else
        log_info "安全缓解规则已存在，无需变更。"
    fi
    return 0
}

# 安全缓解状态（0=已启用 1=未完全启用）
security_mitigation_status() {
    local rule
    for rule in "blacklist esp4" "blacklist esp6" "blacklist rxrpc"; do
        grep -Fqx "$rule" "$SECURITY_MODPROBE_CONF" 2>/dev/null || return 1
    done
    if ! current_kernel_disables_aead; then
        grep -Fqx "blacklist algif_aead" "$SECURITY_MODPROBE_CONF" 2>/dev/null || return 1
    fi
    return 0
}

# ==============================================================================
#  内存安全计算引擎 (Memory Safety Clamp) - 针对 512M/768M/1G 小机器防 OOM 核心算法
# ==============================================================================
get_safe_memory_limits() {
    local mem_kb
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 1048576)
    MEM_TOTAL_MB=$(( mem_kb / 1024 ))

    # 内核页面大小：net.ipv4.tcp_mem 的单位是【内核页面数】而非字节。
    # 硬编码 4096 在 64KB 页面的 ARM64 内核上会把允许页数放大约 16 倍，
    # 使内存钳位完全失效。改用 getconf 探测，探测失败才回退 4KB。
    local page_size
    page_size=$(getconf PAGESIZE 2>/dev/null || true)
    if ! [[ "$page_size" =~ ^[0-9]+$ ]] || (( page_size <= 0 )); then
        page_size=4096
        log_warn "无法探测内核页面大小，按 4KB 计算 tcp_mem 水位。"
    fi

    # 1. 计算全局 TCP 内存池水位 (net.ipv4.tcp_mem，单位为内核页面数)
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

    # 按内存分档的网卡接收队列：小机器 4096 足够，大机器才需要 10000
    TARGET_BACKLOG=4096
    (( MEM_TOTAL_MB >= 1024 )) && TARGET_BACKLOG=10000
}

# ==============================================================================
#  sysctl 持久化管理函数
#
#  为什么用"段标记"而不是拆成多个文件：
#  /etc/sysctl.d/ 按【文件名字典序】加载，后加载者覆盖先加载者。'-'(0x2d) 小于
#  '.'(0x2e)，因此 99-bbr-v3-pro-qdisc.conf 会排在 99-bbr-v3-pro.conf 之前，
#  拆文件会让调优段永久压过算法段（用户"切 cake 后重启"会静默回到 fq）。
#  单文件分段可以保证"段间互不清除"，前提是两个段的键集合不重叠。
# ==============================================================================

# 段标记不配对（文件被截断）时拒绝改写，避免静默吞掉后续内容
assert_sysctl_sections_intact() {
    local open
    [[ -f "$SYSCTL_CONF" ]] || return 0
    open=$($SUDO awk '/^# >>> /{n++} /^# <<< /{n--} END{print n+0}' "$SYSCTL_CONF" 2>/dev/null || echo 0)
    if (( open != 0 )); then
        log_error "$SYSCTL_CONF 段标记不配对（${open} 个段未闭合），已跳过改写以免丢内容。"
        log_info "请检查该文件，或删除后让脚本重建：rm -f $SYSCTL_CONF"
        return 1
    fi
    return 0
}

# 按段替换：删除同名段后重写。
#
# 实现要点（教训）：绝不能在这里用 awk 的 nextfile。
# nextfile 的语义是"停止处理当前文件"，因此当目标段【不是最后一段】时，
# 它会把目标段之后的所有内容一并丢掉 —— 实测中"写 qdisc 段把后面的
# tune 段整个截断"就是这么发生的，正好毁掉本机制要保护的东西。
# 正确做法是用 skip 标志在流式处理中跳过目标段，其余内容原样保留。
replace_sysctl_section() {
    local section="$1" tmp content
    $SUDO touch "$SYSCTL_CONF" || return 1
    assert_sysctl_sections_intact || return 1

    tmp="$(mktemp)"
    content="$(cat)"

    {
        $SUDO awk -v s="$section" '
            $0 == "# >>> " s { skip = 1; next }
            $0 == "# <<< " s { skip = 0; next }
            !skip { print }
        ' "$SYSCTL_CONF"
        echo "# >>> $section"
        printf '%s\n' "$content"
        echo "# <<< $section"
    } > "$tmp"

    $SUDO cp "$tmp" "$SYSCTL_CONF"
    rm -f "$tmp"
    return 0
}

# ==============================================================================
#  sysctl 写入校验
#  原实现全部是 `sysctl -w xxx=yyy >/dev/null 2>&1`，失败被静默吞掉，
#  用户会看到"已生效"但实际未生效。这里统一改为写入 + 回读比对。
# ==============================================================================
SYSCTL_FAILURES=0
SYSCTL_FAIL_KEYS=""

# 把任意空白序列（空格/制表符）压成单个空格并去掉首尾空白。
# 必需：sysctl -n 对多值参数（tcp_rmem/tcp_wmem/tcp_mem）输出的是【制表符】
# 分隔，而写入时用的是空格。只做 tr -s ' ' 不会处理制表符，会造成
# "数值完全相同却判定为未采纳" 的假阴性。
sysctl_norm() {
    printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

sysctl_apply_verify() {
    local key="$1" val="$2" want got
    if ! $SUDO sysctl -w "$key=$val" >/dev/null 2>&1; then
        SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
        SYSCTL_FAIL_KEYS="${SYSCTL_FAIL_KEYS} ${key}"
        log_warn "内核拒绝写入 ${key}=${val}（可能超出上限或该内核不支持）"
        return 1
    fi
    want="$(sysctl_norm "$val")"
    got="$(sysctl_norm "$(sysctl -n "$key" 2>/dev/null || true)")"
    if [[ "$got" != "$want" ]]; then
        SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
        SYSCTL_FAIL_KEYS="${SYSCTL_FAIL_KEYS} ${key}"
        log_warn "${key} 未被完全采纳：期望 [${want}]，实际 [${got}]"
        return 1
    fi
    return 0
}

sysctl_report() {
    if (( SYSCTL_FAILURES > 0 )); then
        log_warn "本次共 ${SYSCTL_FAILURES} 个参数未完全生效：${SYSCTL_FAIL_KEYS}"
        log_warn "常见原因：内核未编译该参数、值超出内核硬上限、或小内存机器水位偏低。"
        return 1
    fi
    log_success "全部内核参数已写入并通过回读校验。"
    return 0
}

# 每个顶层操作开始时复位计数器，保证一次操作只出一份报告。
# 调优函数会调用 apply_bbr_and_qdisc（它自己也会 report 一次），
# 若不复位就会出现"同一次操作报告两遍"的重复输出。
sysctl_reset_counters() {
    SYSCTL_FAILURES=0
    SYSCTL_FAIL_KEYS=""
}

# ==============================================================================
#  调优参数的安全取值（避免影响同机其它服务）
#
#  注意：这两个函数在"跳过"时会设置 SKIP_* 标记，持久化写入必须据此
#  决定是否落盘、或落盘为当前实际值。否则会出现"运行态正确跳过、配置文件
#  却写死一个更小的值"，重启后被静默降级（例如 somaxconn 系统默认 8192，
#  配置文件写 4096，重启即从 8192 降到 4096）。
# ==============================================================================

# tcp_mem 是全局 TCP 内存池水位。小于 256MB 的机器按 10/25/40% 算出的水位
# 会低于内核默认值（默认量级 9501/12669/19003 pages），反而收紧吞吐，因此跳过。
apply_safe_tcp_mem() {
    local mem_mb="${MEM_TOTAL_MB:-0}"
    SKIP_TCP_MEM=0
    if (( mem_mb > 0 && mem_mb < 256 )); then
        log_warn "物理内存 ${mem_mb}MB 偏小，按比例算得的 tcp_mem 水位低于内核默认值，已跳过该项。"
        SKIP_TCP_MEM=1
        return 0
    fi
    sysctl_apply_verify net.ipv4.tcp_mem "$TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX"
}

# somaxconn 是全系统 listen backlog 上限，影响同机所有服务（Caddy/Nginx/Redis）。
# 只在系统当前值偏小时提高；若当前值已经更高，则运行态不动、持久化也不写死，
# 避免重启后把系统降到 4096。
apply_safe_somaxconn() {
    local cur
    SKIP_SOMAXCONN=0
    cur="$(sysctl -n net.core.somaxconn 2>/dev/null || echo 128)"
    if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= 4096 )); then
        log_info "net.core.somaxconn 当前为 ${cur}，已不低于 4096，保持不变（也不会写入配置文件）。"
        SKIP_SOMAXCONN=1
        return 0
    fi
    sysctl_apply_verify net.core.somaxconn 4096
}

# 生成 "net.core.somaxconn / net.ipv4.tcp_mem" 这两行持久化内容。
# 被跳过时输出提示注释而不是写死数值，保证"重启后不会比现在更差"。
emit_guarded_tune_lines() {
    if (( ${SKIP_SOMAXCONN:-0} )); then
        echo "# net.core.somaxconn 保持不变（系统当前值已不低于 4096，本次未改动）"
    else
        echo "net.core.somaxconn = 4096"
    fi
    if (( ${SKIP_TCP_MEM:-0} )); then
        echo "# net.ipv4.tcp_mem 保持不变（物理内存偏小，本次未改动）"
    else
        echo "net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX"
    fi
}

# 加载队列调度内核模块（探测函数：只判断可用性，不产生校验副作用）
load_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"
    local prev current

    if ! lsmod 2>/dev/null | grep -q "^${module_name//-/_}"; then
        $SUDO modprobe "$module_name" 2>/dev/null || true
    fi

    # 探测方式：先记下原值，写入目标值确认被采纳，再写回原值。
    # 不使用 sysctl_apply_verify，避免把探测失败计入 SYSCTL_FAILURES。
    prev="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if ! $SUDO sysctl -w net.core.default_qdisc="$qdisc_name" >/dev/null 2>&1; then
        return 1
    fi
    current="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    [[ -n "$prev" ]] && $SUDO sysctl -w net.core.default_qdisc="$prev" >/dev/null 2>&1 || true

    [[ "$current" == "$qdisc_name" ]] && return 0
    return 1
}

# ==============================================================================
#  网卡队列即时切换
#  net.core.default_qdisc 只影响【新建】队列，已经挂在出口网卡上的 root qdisc
#  不会随之改变。因此除写 sysctl 外，还需对当前默认路由出口网卡执行
#  `tc qdisc replace`，这才是真正的"立即生效"。
# ==============================================================================

# 取默认路由（v4 + v6）的出口网卡名
get_default_route_ifaces() {
    { ip -o route show default 2>/dev/null || true
      ip -o -6 route show default 2>/dev/null || true
    } | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u
}

# 把队列调度模块声明为开机加载。
#
# 背景：fq 是内核内置（CONFIG_NET_SCH_FQ=y），开机即可用；
# 而 cake / fq_codel / fq_pie 在本项目内核中是模块（=m）。
# 若只在运行时 modprobe、不写 modules-load.d，重启后 systemd-sysctl
# 应用 net.core.default_qdisc=cake 时模块可能尚未加载，该行会被忽略，
# 队列静默回退 —— 表现为"设置成功但重启后失效"。
persist_qdisc_module() {
    local qdisc="$1"
    local module_name="sch_$qdisc"

    # fq 为内核内置，无需声明；同时清理可能残留的旧声明
    if [[ "$qdisc" == "fq" ]]; then
        $SUDO rm -f "$MODULES_CONF"
        return 0
    fi

    # 确认模块确实存在再写，避免写入一个加载不了的条目
    if modinfo "$module_name" >/dev/null 2>&1 || lsmod 2>/dev/null | grep -q "^${module_name//-/_}"; then
        echo "$module_name" | $SUDO tee "$MODULES_CONF" >/dev/null
        log_info "已声明开机加载模块: $module_name ($MODULES_CONF)"
    else
        # 可能是内置或该内核不支持，清理旧声明并如实说明
        $SUDO rm -f "$MODULES_CONF"
        log_warn "$module_name 不可作为模块加载（可能内置或内核不支持），未写入开机加载声明。"
    fi
    return 0
}

# 把出口网卡的 root qdisc 替换为指定算法。
# 失败时从 sysctl 读取实际生效值并写回，避免把网卡队列留在中间状态。
# 返回 1 仅在"所有网卡都替换失败且回写也未成功"时发生。
apply_qdisc_to_active_interfaces() {
    local qdisc="$1" iface rc applied=0 total=0
    if ! command -v tc >/dev/null 2>&1; then
        log_warn "缺少 tc(iproute2)，跳过网卡队列即时切换；重启后由 default_qdisc 生效。"
        return 0
    fi

    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        total=$((total + 1))
        if $SUDO tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1; then
            log_info "网卡 $iface 的 root qdisc 已即时切换为 $qdisc"
            applied=$((applied + 1))
        else
            log_warn "网卡 $iface 切换 $qdisc 失败，正在恢复原队列..."
            rc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
            [[ -n "$rc" ]] && $SUDO tc qdisc replace dev "$iface" root "$rc" >/dev/null 2>&1 || true
        fi
    done < <(get_default_route_ifaces)

    if (( total == 0 )); then
        log_warn "未找到默认路由出口网卡，跳过队列即时切换（重启后由 default_qdisc 生效）。"
        return 0
    fi
    (( applied > 0 )) && return 0
    return 1
}

# 回读网卡实际队列，并区分"sysctl 已生效"与"网卡已切换"两个层次
report_qdisc_application() {
    local qdisc="$1" iface cur matched=0
    command -v tc >/dev/null 2>&1 || return 0

    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        cur="$(tc qdisc show dev "$iface" 2>/dev/null | awk '/^qdisc/ {print $2; exit}')"
        if [[ "$cur" == "$qdisc" ]]; then
            log_success "网卡 $iface 实际队列: $cur（已即时生效）"
            matched=1
        else
            log_warn "网卡 $iface 实际队列: ${cur:-未知}，期望 $qdisc"
        fi
    done < <(get_default_route_ifaces)

    if (( matched == 0 )); then
        log_warn "网卡层未即时切换：内核参数 default_qdisc 已生效，但既有队列要到网卡重置或重启后才替换。"
        log_warn "如需立即强制：$SUDO tc qdisc replace dev <网卡> root $qdisc"
    fi
    return 0
}

# 应用拥塞控制算法与队列
apply_bbr_and_qdisc() {
    local algo="${1:-bbr}"
    local qdisc="${2:-fq}"

    sysctl_reset_counters
    log_info "正在配置拥塞算法 [$algo] 与队列调度 [$qdisc]..."
    load_qdisc_module "$qdisc" || true

    sysctl_apply_verify net.core.default_qdisc "$qdisc"
    sysctl_apply_verify net.ipv4.tcp_congestion_control "$algo"

    # 网卡层即时生效（sysctl 只影响新建队列）
    apply_qdisc_to_active_interfaces "$qdisc" || log_warn "网卡队列即时切换失败，重启后由 default_qdisc 生效。"

    # 算法只写 qdisc 段，不触碰 tune 段（调优参数会原样保留）
    replace_sysctl_section "qdisc" <<EOF
# bbr-v3-pro: congestion control & qdisc
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $algo
EOF

    # 模块化编译的队列算法必须在开机早期加载：
    # fq 是内核内置（CONFIG_NET_SCH_FQ=y），无需处理；
    # cake / fq_codel / fq_pie 均为模块（=m），若不在 modules-load.d 中
    # 声明，重启后 systemd-sysctl 应用 default_qdisc 时模块可能尚未加载，
    # 该行会被忽略，队列静默回退到默认值 —— 表现为"设置成功但重启后失效"。
    persist_qdisc_module "$qdisc"

    $SUDO sysctl --system >/dev/null 2>&1
    sysctl_report || log_warn "部分参数未生效，持久化配置已写入 $SYSCTL_CONF。"
    report_qdisc_application "$qdisc"

    log_success "配置已生效并持久化至: $SYSCTL_CONF"
    log_info "  当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
    local eff_qdisc; eff_qdisc="$(current_effective_qdisc)"
    if [[ -n "$eff_qdisc" ]]; then
        log_info "  当前队列调度算法: ${eff_qdisc} (网卡实际生效)"
    else
        log_info "  当前队列调度算法: $(sysctl -n net.core.default_qdisc) (内核默认)"
    fi
    # 算法部分的成败已在上面 report 过，这里清空计数，避免调用方
    # （如 AI 预设）的最终报告把同一批失败重复统计一遍。
    sysctl_reset_counters
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

    # 算法归 qdisc 段，本函数只负责 tune 段
    apply_bbr_and_qdisc "$algo" "$qdisc"

    # 1. 运行时立即应用（算法参数已由 apply_bbr_and_qdisc 写入并校验）
    # 复位跳过标记：这两个是全局变量，且 apply_safe_* 是否跳过取决于系统现状
    SKIP_SOMAXCONN=0
    SKIP_TCP_MEM=0
    sysctl_apply_verify net.core.rmem_max "$TARGET_SOCKET_BYTES"
    sysctl_apply_verify net.core.wmem_max "$TARGET_SOCKET_BYTES"
    sysctl_apply_verify net.core.netdev_max_backlog "$TARGET_BACKLOG"
    apply_safe_somaxconn
    sysctl_apply_verify net.ipv4.tcp_rmem "4096 87380 $TARGET_SOCKET_BYTES"
    sysctl_apply_verify net.ipv4.tcp_wmem "4096 65536 $TARGET_SOCKET_BYTES"
    apply_safe_tcp_mem
    sysctl_apply_verify net.ipv4.tcp_limit_output_bytes "$output_bytes"
    sysctl_apply_verify net.ipv4.tcp_slow_start_after_idle "0"
    sysctl_apply_verify net.ipv4.tcp_window_scaling "1"
    sysctl_apply_verify net.ipv4.tcp_mtu_probing "1"
    sysctl_apply_verify net.ipv4.tcp_notsent_lowat "16384"

    # 2. 持久化写入（只替换 tune 段）
    replace_sysctl_section "tune" <<EOF
# bbr-v3-pro: AI Gateway & High-Throughput Cross-Pacific Tuning
# UDP / QUIC Buffer (Optimized for Hysteria 2 & Caddy HTTP/3)
net.core.rmem_max = $TARGET_SOCKET_BYTES
net.core.wmem_max = $TARGET_SOCKET_BYTES
net.core.netdev_max_backlog = $TARGET_BACKLOG
$(emit_guarded_tune_lines)

# TCP Buffer & Low Latency (Optimized for VLESS & AI Model Streaming)
net.ipv4.tcp_rmem = 4096 87380 $TARGET_SOCKET_BYTES
net.ipv4.tcp_wmem = 4096 65536 $TARGET_SOCKET_BYTES
net.ipv4.tcp_limit_output_bytes = $output_bytes
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
EOF

    $SUDO sysctl --system >/dev/null 2>&1
    sysctl_report || log_warn "部分参数未生效，详见上方告警。"

    log_success "AI 网关与跨洋全栈优化预设已写入：$SYSCTL_CONF（tune 段）"
    echo -e "  ${BOLD}核心调优摘要：${PLAIN}"
    echo -e "  - 拥塞控制 / 队列 : ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)${PLAIN}"
    echo -e "  - 单 Socket 缓冲区: ${GREEN}$((TARGET_SOCKET_BYTES / 1024 / 1024)) MB${PLAIN} (已实施小内存安全钳位)"
    echo -e "  - 全局 TCP 水位线 : ${GREEN}${TCP_MEM_MIN} / ${TCP_MEM_PRESSURE} / ${TCP_MEM_MAX} Pages${PLAIN} (最大占内存 40%)"
    echo -e "  - 网卡接收队列    : ${GREEN}${TARGET_BACKLOG}${PLAIN} (按物理内存 ${MEM_TOTAL_MB}MB 分档，防 Hy2 端口跳跃瞬时丢包)"
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

    read -r -p "请输入 VPS 峰值带宽 (Mbps，直接回车默认 100): " user_bw
    user_bw=$(echo "$user_bw" | tr -d '[:space:]')
    [[ -z "$user_bw" || ! "$user_bw" =~ ^[0-9]+$ ]] && user_bw=100

    echo -e "\n请选择您的主要目标链路延迟特征："
    echo -e "  1. 美西 / 欧美长链路 (RTT 约 150ms ~ 250ms，美区住宅/VPS 推荐)"
    echo -e "  2. 亚太近距离链路 (RTT 约 30ms ~ 80ms，香港/日本/新加坡)"
    echo -e "  3. 自定义输入延迟 (ms)"
    read -r -p "请选择 [1-3] (回车默认 1): " rtt_choice
    rtt_choice=$(echo "$rtt_choice" | tr -d '[:space:]')
    
    local rtt_ms=180
    case "$rtt_choice" in
        2) rtt_ms=60 ;;
        3) 
            read -r -p "请输入真实单程延迟 (毫秒，例如 180): " user_rtt
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

    # 算法归 qdisc 段，本函数只负责 tune 段
    apply_bbr_and_qdisc "$algo" "$qdisc"

    SKIP_SOMAXCONN=0
    SKIP_TCP_MEM=0
    sysctl_apply_verify net.core.rmem_max "$calculated_buffer"
    sysctl_apply_verify net.core.wmem_max "$calculated_buffer"
    sysctl_apply_verify net.core.netdev_max_backlog "$TARGET_BACKLOG"
    apply_safe_somaxconn
    sysctl_apply_verify net.ipv4.tcp_rmem "4096 87380 $calculated_buffer"
    sysctl_apply_verify net.ipv4.tcp_wmem "4096 65536 $calculated_buffer"
    apply_safe_tcp_mem
    sysctl_apply_verify net.ipv4.tcp_limit_output_bytes "$output_bytes"
    sysctl_apply_verify net.ipv4.tcp_slow_start_after_idle "0"
    sysctl_apply_verify net.ipv4.tcp_window_scaling "1"
    sysctl_apply_verify net.ipv4.tcp_mtu_probing "1"
    sysctl_apply_verify net.ipv4.tcp_notsent_lowat "16384"

    replace_sysctl_section "tune" <<EOF
# bbr-v3-pro: Smart BDP Dynamic Tuning (BW: ${user_bw}Mbps, RTT: ${rtt_ms}ms)
net.core.rmem_max = $calculated_buffer
net.core.wmem_max = $calculated_buffer
net.core.netdev_max_backlog = $TARGET_BACKLOG
$(emit_guarded_tune_lines)
net.ipv4.tcp_rmem = 4096 87380 $calculated_buffer
net.ipv4.tcp_wmem = 4096 65536 $calculated_buffer
net.ipv4.tcp_limit_output_bytes = $output_bytes
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
EOF

    $SUDO sysctl --system >/dev/null 2>&1
    sysctl_report || log_warn "部分参数未生效，详见上方告警。"

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

    local algo="bbr"
    local qdisc="fq"
    local output_bytes="4194304"

    local apac_buffer=$(( 8 * 1024 * 1024 ))
    if (( apac_buffer > MAX_SOCKET_BYTES )); then
        apac_buffer=$MAX_SOCKET_BYTES
    fi

    # 算法归 qdisc 段，本函数负责完整生效 BBR + FQ
    apply_bbr_and_qdisc "$algo" "$qdisc"

    # 1. 运行时立即应用并回读校验
    sysctl_apply_verify net.core.rmem_max "$apac_buffer"
    sysctl_apply_verify net.core.wmem_max "$apac_buffer"
    sysctl_apply_verify net.ipv4.tcp_rmem "4096 131072 $apac_buffer"
    sysctl_apply_verify net.ipv4.tcp_wmem "4096 16384 $apac_buffer"
    sysctl_apply_verify net.ipv4.tcp_slow_start_after_idle "0"
    sysctl_apply_verify net.ipv4.tcp_limit_output_bytes "$output_bytes"

    # 2. 持久化写入（只替换 tune 段）
    replace_sysctl_section "tune" <<EOF
# bbr-v3-pro: APAC Low-Latency Tuning
net.core.rmem_max = $apac_buffer
net.core.wmem_max = $apac_buffer
net.ipv4.tcp_rmem = 4096 131072 $apac_buffer
net.ipv4.tcp_wmem = 4096 16384 $apac_buffer
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_limit_output_bytes = $output_bytes
EOF

    $SUDO sysctl --system >/dev/null 2>&1
    sysctl_report || log_warn "部分参数未生效，详见上方告警。"
    log_success "亚太机器低延迟优化已生效。"
}

# ==============================================================================
#  清空网络优化配置 (一键回滚出厂默认)
# ==============================================================================
clear_network_tuning() {
    log_info "正在清空所有自定义网络优化持久化配置..."
    $SUDO rm -f "$SYSCTL_CONF" "$MODULES_CONF"
    $SUDO sysctl --system >/dev/null 2>&1 || true

    # 删配置只能清掉"开机重新加载"的来源，当前内核里已写入的运行态值不会
    # 自动回退。这里把仍在生效的键列出来，避免用户以为已经还原干净。
    local key cur
    echo -e "${BOLD}以下运行态参数仍然生效（重启后才会恢复内核默认）：${PLAIN}"
    for key in net.core.default_qdisc net.ipv4.tcp_congestion_control \
               net.core.rmem_max net.core.wmem_max net.core.netdev_max_backlog \
               net.core.somaxconn net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
               net.ipv4.tcp_mem \
               net.ipv4.tcp_limit_output_bytes net.ipv4.tcp_slow_start_after_idle \
               net.ipv4.tcp_notsent_lowat net.ipv4.tcp_window_scaling \
               net.ipv4.tcp_mtu_probing; do
        cur="$(sysctl -n "$key" 2>/dev/null || true)"
        [[ -n "$cur" ]] && printf '    %-38s = %s\n' "$key" "$cur"
    done

    if [[ ! -f "$SYSCTL_CONF" && ! -f "$MODULES_CONF" ]]; then
        log_success "已彻底清空持久化配置并重载系统默认参数。"
    else
        log_error "部分配置文件未能删除，请手工检查 $SYSCTL_CONF / $MODULES_CONF"
        return 1
    fi
    log_warn "以上运行态参数将保持到重启；重启后系统按发行版默认值运行。"
    return 0
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
    read -r -p "是否需要自定义查询特定端口？(输入端口号，回车跳过): " custom_p
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
#  BBRv3 版本判定
#  背景: 本项目内核把拥塞控制编进内核 (CONFIG_TCP_CONG_BBR=y)，
#  内建模块没有独立 .ko，modinfo 取不到内容，只靠 modinfo 会必然误判为
#  "非 v3"。因此增加 sysfs version 与内核发行版本命名两条交叉验证路径。
# ==============================================================================
bbr_is_v3() {
    local bbr_mod bbr_ver krel
    bbr_mod=$(modinfo tcp_bbr 2>/dev/null || true)
    bbr_ver=$(echo "$bbr_mod" | awk '/^version:/ {print $2}')
    [[ "$bbr_ver" == "3" ]] && return 0

    # sysfs version 强校验
    if [[ -r /sys/module/tcp_bbr/version ]]; then
        [[ "$(cat /sys/module/tcp_bbr/version 2>/dev/null)" == "3" ]] && return 0
        return 1
    fi

    # 内核发行版本强校验（杜绝官方原版 BBRv1 内核误报，如 6.12.0-bbrv3）
    krel="$(uname -r 2>/dev/null || true)"
    if [[ "$krel" =~ -bbrv3 ]]; then
        return 0
    fi

    return 1
}

# 读取当前出口网卡【实际生效】的 root qdisc。
# 为什么需要它：net.core.default_qdisc 只是"新建队列的默认值"，网卡上已经存在的
# root qdisc 不会随之改变。只显示 default_qdisc 会误导用户 ——
# 例如切到 cake 后 default_qdisc 仍显示 fq，而网卡实际已经在用 cake。
current_effective_qdisc() {
    local iface cur
    command -v tc >/dev/null 2>&1 || { echo ""; return 0; }
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        cur="$(tc qdisc show dev "$iface" 2>/dev/null | awk '/^qdisc/ {print $2; exit}')"
        [[ -n "$cur" ]] && { echo "$cur"; return 0; }
    done < <(get_default_route_ifaces)
    echo ""
}

# ==============================================================================
#  获取当前网络核心状态 (用于顶部仪表盘与状态检查)
# ==============================================================================
get_network_metrics() {
    METRIC_KERNEL=$(uname -r)
    METRIC_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    METRIC_QDISC_DEFAULT=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    METRIC_QDISC_IFACE=$(current_effective_qdisc)
    if [[ -n "$METRIC_QDISC_IFACE" && "$METRIC_QDISC_IFACE" != "$METRIC_QDISC_DEFAULT" ]]; then
        METRIC_QDISC="${METRIC_QDISC_IFACE} (网卡实际) / ${METRIC_QDISC_DEFAULT} (内核默认)"
    elif [[ -n "$METRIC_QDISC_IFACE" ]]; then
        METRIC_QDISC="$METRIC_QDISC_IFACE"
    else
        METRIC_QDISC="$METRIC_QDISC_DEFAULT"
    fi

    if bbr_is_v3; then
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
    if [[ -f "$SYSCTL_CONF" ]] && grep -Eq '^[[:space:]]*net\.ipv4\.tcp_mem[[:space:]]*=' "$SYSCTL_CONF" 2>/dev/null; then
        METRIC_MEM_DISPLAY="${mem_total} MB (已开启 40% 防 OOM 保护)"
    else
        METRIC_MEM_DISPLAY="${mem_total} MB (系统默认)"
    fi

    if security_mitigation_status; then
        METRIC_SECURITY_DISPLAY="${GREEN}已启用 (esp4/esp6/rxrpc/algif_aead 黑名单)${PLAIN}"
    else
        METRIC_SECURITY_DISPLAY="${YELLOW}未启用${PLAIN}"
    fi
}

check_bbr_status() {
    get_network_metrics
    echo -e "\n${BOLD}==================== BBR 状态与系统体检 ====================${PLAIN}"
    echo -e "脚本版本       : ${GREEN}$BBR_SCRIPT_VERSION${PLAIN}"
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
    echo -e "安全缓解状态   : ${METRIC_SECURITY_DISPLAY}"
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

# ==============================================================================
#  下载内核产物（含 SHA256 完整性校验）
#  Release 内若附带 SHA256SUMS 则逐包校验；没有则明确告知"无法校验"，
#  不把"没校验"伪装成"校验通过"。
# ==============================================================================
fetch_kernel_assets() {
    local asset_urls="$1"
    local workdir="$2"
    local url base name want got
    local -a debs=()

    for url in $asset_urls; do
        base="${url##*/}"

        # 明确排除 linux-libc-dev：它是用户态开发头文件，不属于内核本体。
        # 主线内核版本（如 7.2.8）的 libc-dev 会与发行版自带的 libc6-dev
        # 产生版本冲突，导致后续 apt-get upgrade 报依赖损坏并锁死。
        # 内核镜像/头文件的编译并不需要安装这个包。
        if [[ "$base" == linux-libc-dev* ]]; then
            log_info "跳过 $base（用户态开发头文件，会与发行版 libc6-dev 冲突，内核安装不需要）"
            continue
        fi

        log_info "正在下载: $base"
        if ! wget -q --show-progress "$url" -P "$workdir"; then
            log_error "下载失败: $url"
            return 1
        fi
        [[ "$base" == linux-*.deb ]] && debs+=("$base")
    done

    if (( ${#debs[@]} == 0 )); then
        log_error "下载完成，但未取得任何 linux-*.deb 文件。"
        return 1
    fi

    if [[ ! -f "$workdir/SHA256SUMS" ]]; then
        log_warn "该 Release 未提供 SHA256SUMS，本次安装无法做完整性校验。"
        log_warn "如需校验，请自行比对发布页给出的校验值，或改用提供校验和的 Release。"
        return 0
    fi

    for name in "${debs[@]}"; do
        want=$(awk -v f="$name" '$2 == f || $2 == "*"f {print $1; exit}' "$workdir/SHA256SUMS" 2>/dev/null || true)
        if [[ -z "$want" ]]; then
            log_warn "SHA256SUMS 中未找到 $name 的校验值，跳过该校验。"
            continue
        fi
        got=$(sha256sum "$workdir/$name" 2>/dev/null | awk '{print $1}')
        if [[ "$want" != "$got" ]]; then
            log_error "校验和不匹配，安装包可能已损坏或被篡改，已中止: $name"
            log_error "  期望: $want"
            log_error "  实际: $got"
            return 1
        fi
        log_success "SHA256 校验通过: $name"
    done
    return 0
}

install_bbrv3_kernel() {
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
        latest_tag=$(echo "$release_data" | jq -r --arg filter "$arch_filter" '
          if type=="array" then
            map(
              select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
              | select((.tag_name | test("-max$"; "i")) | not)
            )
            | sort_by(.published_at)
            | .[-1].tag_name // ""
          else "" end
        ' 2>/dev/null || true)
    fi

    # 私有源无可用内核包时的处理。
    # 注意：用户显式设置 BBR_REPO 的意图通常是"只使用自己编译的内核"，
    # 因此默认只提示、不自动切换；需要在明确同意后才回退到上游中央源。
    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        if [[ "$target_repo" != "$UPSTREAM_REPO" ]]; then
            log_warn "私有仓库 [$target_repo] 未发布适用于 [$ARCH] 的内核包。"
            if [[ "${BBR_ALLOW_UPSTREAM:-0}" != "1" ]]; then
                log_info "你的配置意图是仅使用自有内核，因此脚本不会自动改用第三方源。"
                log_info "如确实要安装上游中央源 [$UPSTREAM_REPO] 构建的内核，请显式执行其一："
                log_info "  1) BBR_ALLOW_UPSTREAM=1 bash $0 --install-kernel"
                log_info "  2) BBR_REPO=$UPSTREAM_REPO bash $0 --install-kernel"
                return 1
            fi
            log_warn "BBR_ALLOW_UPSTREAM=1 已设置，将回退到上游中央源（安装第三方构建的内核）。"
            target_repo="$UPSTREAM_REPO"
            base_url="https://api.github.com/repos/${target_repo}/releases"
            release_data=$(gh_api_get "$base_url" 2>/dev/null || true)
            if [[ -n "$release_data" ]]; then
                latest_tag=$(echo "$release_data" | jq -r --arg filter "$arch_filter" '
                  if type=="array" then
                    map(
                      select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
                      | select((.tag_name | test("-max$"; "i")) | not)
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
      if type=="array" then
        .[] | select(.tag_name == $tag) | .assets[].browser_download_url
        | select(test("(-dbg_|-dbgsym_)"; "i") | not)
      else empty end
    ' 2>/dev/null || true)

    if [[ -z "$asset_urls" ]]; then
        log_error "未能从 Release [$latest_tag] 解析出可下载的内核安装包。"
        log_info "常见原因：GitHub API 限流（可先 export GITHUB_TOKEN=你的令牌 再重试）、"
        log_info "或该 Release 未附带 linux-*.deb 资源。"
        return 1
    fi

    local workdir="/tmp/bbr_kernel_install"
    rm -rf "$workdir" && mkdir -p "$workdir"

    fetch_kernel_assets "$asset_urls" "$workdir" || return 1

    # 验证 deb 包完整性（能否被 dpkg 读取）
    local any_deb=0
    for deb in "$workdir"/linux-*.deb; do
        [[ -f "$deb" ]] || continue
        any_deb=1
        if ! dpkg-deb -I "$deb" >/dev/null 2>&1; then
            log_error "安装包损坏或 dpkg 无法读取: $deb"
            rm -rf "$workdir"
            return 1
        fi
    done
    if (( any_deb == 0 )); then
        log_error "下载完成但未取得任何 linux-*.deb，已中止安装。"
        rm -rf "$workdir"
        return 1
    fi

    # 下载前置检查：若 deb 版本与已装内核完全相同，先征求确认，
    # 避免白跑一遍 150MB 的解包 + initramfs + GRUB 生成。
    local deb_ver cur_ver need_prompt=0
    for deb in "$workdir"/linux-image-*.deb; do
        [[ -f "$deb" ]] || continue
        deb_ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
        cur_ver="$(dpkg-query -W -f='${Version}' "$(dpkg-deb -f "$deb" Package 2>/dev/null)" 2>/dev/null || true)"
        if [[ -n "$deb_ver" && "$deb_ver" == "$cur_ver" ]]; then
            log_info "当前内核版本 (${cur_ver}) 与要安装的版本相同，无需升级。"
            need_prompt=1
        fi
    done
    if (( need_prompt )); then
        read -r -p "是否仍要重新安装同版本内核？(y/N): " reinstall_same
        if [[ "$reinstall_same" != "y" && "$reinstall_same" != "Y" ]]; then
            log_info "已取消，未做任何改动。"
            rm -rf "$workdir"
            return 0
        fi
        log_warn "将重新安装同版本内核（不会升级到更新的版本）。"
    fi

    log_info "正在安全安装新内核 (保留旧内核作为救援保底)..."
    # 判据说明（教训）：
    # 只比对 /boot/vmlinuz-* 的【文件名列表】是错的 —— 同版本重装时文件名不变，
    # 会被误判为"dpkg 未替换内核"，而实际上 dpkg 可能确实完成了重装。
    # 因此：
    #   - 主判据 = dpkg 自己的退出码（失败才说明真的没装上）
    #   - 辅助判据 = 内核映像的 mtime 签名，用于区分"真的重装了"与"确实什么都没做"
    local before_sig after_sig
    kernel_sig() {
        ls -l --time-style=+%s /boot/vmlinuz-* 2>/dev/null \
            | awk '{print $6, $7}' | sort || true
    }
    before_sig="$(kernel_sig)"

    if $SUDO dpkg -i "$workdir"/linux-*.deb; then
        after_sig="$(kernel_sig)"
        log_success "内核包安装完成。"
    elif $SUDO apt-get install -f -y; then
        after_sig="$(kernel_sig)"
        log_warn "dpkg -i 返回非零，但 apt-get install -f 修复依赖成功，已继续。"
    else
        log_error "内核安装失败！系统原有内核完整保留未受破坏，请勿重启并检查报错日志。"
        rm -rf "$workdir"
        return 1
    fi

    if [[ -n "$before_sig" && "$before_sig" == "$after_sig" ]]; then
        # dpkg 成功但内核映像没变化：说明装的是与已装版本完全相同的包，
        # /boot 内容被原样重写。这不是失败，但用户需要知道"没有换到新内核"。
        log_warn "内核映像未发生变化：本次安装的版本与已装版本相同（同版本重装）。"
        log_warn "若期望升级到更新的内核，请确认 Release 中的 deb 版本号已递增"
        log_warn "（构建侧需设置 KDEB_PKGVERSION），或等待下一个内核版本的 Release。"
    fi

    log_info "正在更新 GRUB 引导记录..."
    if command -v update-grub &>/dev/null; then
        $SUDO update-grub
    fi
    if command -v update-grub &>/dev/null; then
        local newest_kernel
        newest_kernel=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -n 1 | sed 's|.*/vmlinuz-||')
        if [[ -n "$newest_kernel" ]] && ! grep -q "$newest_kernel" /boot/grub/grub.cfg 2>/dev/null; then
            log_warn "GRUB 配置中未找到内核 $newest_kernel 的引导项，重启后可能仍进入旧内核。"
            log_warn "请人工检查 /boot/grub/grub.cfg 与 update-grub 输出后再重启。"
        fi
    fi
    log_success "内核安装与引导更新流程完成。"
    rm -rf "$workdir"

    read -r -p "新内核需要重启系统才能生效，是否立即重启？(y/n): " do_reboot
    if [[ "$do_reboot" == "y" || "$do_reboot" == "Y" ]]; then
        log_info "系统正在重启..."
        $SUDO reboot
    else
        log_warn "请记得稍后手动执行 reboot 重启系统。"
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
    fallback_kernels=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-image-(unsigned-)?[0-9]/ && ($2 !~ /bbrv3/ && $2 !~ /joeyblog/) {print $2}' | tr '\n' ' ')

    if [[ -z "$fallback_kernels" ]]; then
        log_error "【高危拦截】系统未检测到任何官方备用内核！"
        log_warn "若此时卸载 BBRv3 内核，系统重启后将因无可用内核直接失联变砖！"
        log_info "请先执行: $SUDO apt-get install -y linux-image-cloud-amd64 (或 linux-image-generic) 安装官方内核后再卸载。"
        return 1
    fi

    echo -e "即将卸载以下 BBRv3 内核包: ${YELLOW}$packages_to_remove${PLAIN}"
    echo -e "系统将安全回滚至备用官方内核: ${GREEN}$fallback_kernels${PLAIN}"
    read -r -p "确认卸载并回滚引导吗？(y/n): " confirm_un
    if [[ "$confirm_un" != "y" && "$confirm_un" != "Y" ]]; then
        log_info "操作已取消。"
        return 0
    fi

    log_info "正在安全卸载 BBRv3 内核包..."
    if $SUDO apt-get purge -y $packages_to_remove; then
        log_info "正在更新 GRUB 引导记录..."
        if command -v update-grub &>/dev/null; then
            $SUDO update-grub
        fi
        log_success "BBRv3 内核已成功卸载，GRUB 引导已恢复官方内核！"
        read -r -p "需要重启系统以加载官方内核，是否立即重启？(y/n): " do_rb
        if [[ "$do_rb" == "y" || "$do_rb" == "Y" ]]; then
            log_info "系统正在重启..."
            $SUDO reboot
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
    read -r -p "确认彻底卸载本工具及所有网络配置吗？(y/n): " confirm_all
    if [[ "$confirm_all" != "y" && "$confirm_all" != "Y" ]]; then
        log_info "操作已取消。"
        return 0
    fi

    clear_network_tuning
    $SUDO rm -f "$QUICK_COMMAND_PATH" "$SECURITY_MODPROBE_CONF"
    $SUDO rm -rf /tmp/bbr_kernel_install
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
        echo -e " 脚本版本: ${GREEN}${BBR_SCRIPT_VERSION}${PLAIN}"
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
        echo -e "  ${BOLD}12.${PLAIN} 更新 bbr-v3-pro 到最新版"
        echo -e "  ${BOLD}0.${PLAIN} 退出管理系统"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "快捷唤醒指令: ${GREEN}bbr${PLAIN}"
        echo -e "----------------------------------------------------------------"
        read -r -p "请输入功能编号 [0-12]: " opt
        opt="${opt//[[:space:]]/}"

        case "$opt" in
            1) check_bbr_status ;;
            2) install_bbrv3_kernel ;;
            3) apply_bbr_and_qdisc "bbr" "fq" ;;
            4) apply_bbr_and_qdisc "bbr" "cake" ;;
            5) apply_ai_gateway_tuning ;;
            6) apply_smart_bandwidth_tuning ;;
            7) apply_apac_tuning ;;
            8) check_port_conflicts ;;
            9) clear_network_tuning ;;
            10) uninstall_bbrv3_kernel ;;
            11) uninstall_everything ;;
            12) self_update 0 ;;
            0) exit 0 ;;
            *) log_error "输入无效，请输入 [0-12]！" ;;
        esac

        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# ==============================================================================
#  主入口: CLI 自动化参数解析与调度
# ==============================================================================
#  主入口
#
#  顺序很重要：
#   - check_and_install_deps 两种模式都需要（CLI 的 --install-kernel 依赖 jq 等）
#   - ensure_quick_command / apply_security_mitigations 只在【交互模式】执行，
#     否则会出现自相矛盾的行为 —— 例如 --uninstall-all 要删除快捷命令，
#     却在参数分发之前先被 ensure_quick_command 重新装回来。
# ==============================================================================
check_and_install_deps

if [[ $# -gt 0 ]]; then
    case "$1" in
        --status)
            check_bbr_status
            exit 0
            ;;
        --install-kernel)
            install_bbrv3_kernel
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
        --mitigate-cve)
            apply_security_mitigations 1
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
            show_help
            exit 0
            ;;
        *)
            log_error "未知参数: $1"
            # 常见拼写错误纠错：单横杠、缺横杠、大小写等
            _arg_suggest=""
            case "$1" in
                -update|-Update|-UPDATE)            _arg_suggest="--update" ;;
                update|Update)                      _arg_suggest="--update" ;;
                -version|-v|-V)                     _arg_suggest="--version" ;;
                version)                            _arg_suggest="--version" ;;
                --updata|--updte|--updat)          _arg_suggest="--update" ;;
                -help|-h)                           _arg_suggest="--help" ;;
                help)                               _arg_suggest="--help" ;;
                -status)                            _arg_suggest="--status" ;;
                status)                             _arg_suggest="--status" ;;
                -install-kernel|install-kernel)     _arg_suggest="--install-kernel" ;;
                -apply-bbr|apply-bbr)               _arg_suggest="--apply-bbr" ;;
                -clean|clean)                       _arg_suggest="--clean" ;;
                -mitigate-cve|mitigate-cve|--mitigate) _arg_suggest="--mitigate-cve" ;;
                -check-ports|check-ports)           _arg_suggest="--check-ports" ;;
                -uninstall-kernel|uninstall-kernel) _arg_suggest="--uninstall-kernel" ;;
                -uninstall-all|uninstall-all)       _arg_suggest="--uninstall-all" ;;
                -tune=*|tune=*)                     _arg_suggest="--${1#-}" ;;
            esac
            if [[ -n "$_arg_suggest" ]]; then
                log_info "是否想输入: ${GREEN}${_arg_suggest}${PLAIN} ？"
            fi
            log_info "完整参数列表: $0 --help"
            exit 1
            ;;
    esac
fi

# 交互模式：进入菜单前注册快捷命令并应用安全缓解（不主动卸载模块，防打断 IPsec 隧道）
ensure_quick_command
apply_security_mitigations 0

show_menu
