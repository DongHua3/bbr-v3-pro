# bbr-v3-pro

Linux 服务器网络调优与 BBRv3 主线内核自动化管理系统。提供一条命令安装 BBRv3 内核、TCP/UDP 双栈性能调优与针对小内存 VPS 的防 OOM 内存钳位保护。

- **系统支持**：Debian 12+ / Ubuntu 22.04+ / Ubuntu 24.04+（x86_64 与 arm64）
- **虚拟化支持**：KVM（VirtIO）、Microsoft Hyper-V / Azure（VMBus）、Xen、VMware、裸金属服务器
- **运行模式**：交互式菜单 + CLI 命令行参数双模式（适合批量 Ansible / cloud-init）
- **安全与合规**：CVE-2026-31431 / Dirty Frag 运行时风险防御与精准探测，无广告、无推广外链

---

## 目录

- [核心特性与解决的问题](#核心特性与解决的问题)
- [快速开始](#快速开始)
- [新手全流程指南](#新手全流程指南)
- [调优预设与网络参数详解](#调优预设与网络参数详解)
- [安全防御与 CVE 探测](#安全防御与-cve-探测)
- [安全卸载与引导回滚](#安全卸载与引导回滚)
- [GitHub Actions 云端与本地构建](#github-actions-云端与本地构建)
- [常见问题解答 (FAQ)](#常见问题解答-faq)
- [目录结构说明](#目录结构说明)
- [开源协议](#开源协议)

---

## 核心特性与解决的问题

Linux 发行版官方内核的默认网络参数主要面向通用场景，在跨境高延迟链路、大并发长连接或 512M~1G 小内存 VPS 上容易遭遇性能瓶颈或内存溢出。

| 场景痛点 | 根本原因 | bbr-v3-pro 解决方案 |
|---|---|---|
| **跨国/跨境传输速度跑不满** | 原生 Cubic / BBRv1 算法对丢包过于敏感或测速回落 | 编译集成 Google 最新主线 BBRv3 拥塞控制算法，主动探测 BDP 与 RTT |
| **高突发下 SSH / 交互卡顿** | 队列管理缺失导致网络出现缓冲区膨胀（Bufferbloat） | 默认启用 `fq` 队列调度，支持一键切换 `cake` 队列过滤 ACK 抖动 |
| **小内存 VPS 晚高峰频繁 OOM** | 网络套接字缓冲区无限扩张，吃光物理内存触发系统崩溃 | 引入内存安全引擎（Memory Safety Clamp），全局动态钳位 `tcp_mem` |
| **参数写完不知是否生效** | 传统脚本盲目执行 `sysctl -w` 吞噬错误 | 写入后自动逐项回读内核运行态参数进行断言比对 |
| **换核开机黑屏死机 (Panic)** | 自定义编译内核缺失特定云平台虚拟化驱动 | 全面启用 Microsoft Hyper-V / Azure 驱动矩阵，对齐主流发行版基线 |

---

## 快速开始

### 方式一：交互式菜单（推荐新手）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh)
```

首次运行会自动注册全局快捷命令 `/usr/local/bin/bbr`，之后直接在终端输入 `bbr` 即可唤起管理控制台。

### 方式二：CLI 命令行模式（适合自动化运维 / 批处理）

```bash
# 推荐先下载到本地执行
curl -fsSL -o /tmp/bbr.sh https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh

# 查看当前系统状态
sudo bash /tmp/bbr.sh --status

# 一键安装最新 BBRv3 标准版内核
sudo bash /tmp/bbr.sh --install-kernel

# 应用 AI 网关与跨洋全栈调优 (TCP + UDP)
sudo bash /tmp/bbr.sh --tune=ai-gateway
```

### 交互菜单概览

在终端输入 `bbr` 即可进入主菜单（支持输入数字直接操作）：

```text
================================================================
   bbr-v3-pro Linux 网络调优与 BBRv3 内核管理系统 v1.2.0
================================================================
  1. 查看系统网络栈与内核状态 (含 BBRv3 强校验看板)
  2. 安装 / 更新 BBRv3 内核 (标准稳定版 / 测速 Max 版)
  3. 启用系统原生 BBR + FQ
  4. 启用系统原生 BBR + CAKE (抗晚高峰队列抖动)
  5. 应用 AI 网关与跨洋全栈优化 (UDP+TCP 混合大水管)
  6. 应用 BBR v3 智能带宽动态调优 (按实测 BDP 精算)
  7. 应用亚太短链路低延迟调优 (香港/日本/新加坡直连)
  8. 检查关键 TCP / UDP 端口占用 (排查 80/443/8443)
  9. 清空网络调优参数并恢复系统默认
 10. 安全卸载 BBRv3 内核并回滚至官方内核
 11. 彻底卸载 bbr-v3-pro 工具与所有残留配置
 12. 更新 bbr-v3-pro 管理脚本到最新版
  0. 退出管理系统
================================================================
```

---

## 新手全流程指南

### 第 1 步：查看当前系统状态
```bash
bbr --status
```
若回显显示 `TCP 拥塞控制 : cubic`，说明当前仍在使用系统默认算法。

### 第 2 步：安装 BBRv3 内核
```bash
bbr --install-kernel
```
脚本将自动从 GitHub Releases 检索适配当前架构（x86_64 或 arm64）的最新稳定内核包，比对哈希校验并安装。

### 第 3 步：重启服务器
```bash
sudo reboot
```
内核升级必须重启才能载入引导。

### 第 4 步：确认 BBRv3 内核生效
重启后执行：
```bash
uname -r
```
输出应包含 `-bbrv3` 后缀（如 `7.2.8-bbrv3`）。

### 第 5 步：应用适合您业务的网络调优方案
- **大多数跨境 VPS / 代理 / API 网关**：
  ```bash
  bbr --tune=ai-gateway
  ```
- **香港 / 日本 / 新加坡等亚太低延迟短链路**：
  ```bash
  bbr --tune=apac
  ```

### 第 6 步：核对运行态与持久化状态
再次运行 `bbr --status`，若看到：
```text
TCP 拥塞控制   : bbr (v3)
队列管理算法   : fq
物理内存状态   : 1024 MB (已开启 40% 防 OOM 保护)
持久化优化配置 : 已加载 (/etc/sysctl.d/99-bbr-v3-pro.conf)
```
即代表调优已完整生效，且在下次开机后会自动加载。

---

## 调优预设与网络参数详解

本项目采用 **段标记隔离机制**（`qdisc` 段与 `tune` 段），算法切换与缓冲区调优互不污染。

| CLI 参数 | 适用网络场景 | 优化核心策略 |
|---|---|---|
| `--apply-bbr` | 生产关键业务，不希望调整缓冲区 | 仅将拥塞算法设为 BBR，队列设为 FQ，不更改任何系统缓冲区 |
| `--tune=ai-gateway` | 跨境跨洋、Hysteria 2、Caddy HTTP/3、大模型流式传输 | 放大 UDP/TCP 缓冲区，关闭空闲慢启动（`tcp_slow_start_after_idle=0`），降低 `tcp_notsent_lowat`，按内存自动钳位 |
| `--tune=apac` | 亚太直连线路（RTT < 80ms） | 启用 BBR+FQ，配置 8MB 紧凑型缓冲区，避免过度缓冲引入排队延迟 |
| `--tune=smart` | 明确掌握物理带宽与实际往返时延（RTT） | 通过 BDP 精算公式 `带宽 × 125000 × RTT / 1000 × 3` 计算缓冲区并注入配置 |

### 动态防 OOM 内存钳位算法 (Memory Safety Clamp)
为防止 512MB / 1GB 小内存 VPS 因并发套接字撑爆内存，脚本在执行任何调优时均会自动计算：
1. **全局页面池保护**：动态读取 `/proc/meminfo` 与系统页面大小，将 `net.ipv4.tcp_mem` 的硬上限严格限制在总物理内存的 40% 水位内；
2. **单连接硬顶保护**：单 Socket 最大读写缓冲区取预设计算值与 `物理内存 × 15%` 的较小值；
3. **极小内存豁免**：当物理内存 < 256MB 时，跳过 `tcp_mem` 压缩，避免误杀正常连接。

---

## 安全防御与 CVE 探测

针对近期 Linux 网络栈与加密子系统的已知安全风险，本项目提供纵深防护能力：

### 1. 独立 CVE 探测器
项目包含独立的漏洞暴露面检测工具：
```bash
python3 cve_2026_31431_detector.py
```
- **CVE-2026-31431 检测**：检测当前内核是否暴露 `AF_ALG` userspace AEAD 加密接口，具备主动装载防御（防止探测操作本身反向唤醒内核漏洞模块）；
- **Dirty Frag 检测**：精准检测 `esp4`、`esp6`、`rxrpc` 运行态与黑名单状态。即使系统缺失 `/boot/config-*` 文件，探测器仍会基于内存运行态进行真实研判，杜绝虚假“已收敛”误报。

### 2. 安全缓解规则 (`--mitigate-cve`)
如果您的服务器无需使用原生 IPsec VPN，可显式执行安全加固：
```bash
bbr --mitigate-cve
```
- 写入 `/etc/modprobe.d/99-bbr-v3-pro-security.conf` 永久禁用 `esp4` / `esp6` / `rxrpc` / `algif_aead`；
- 尝试卸载当前未被占用的模块；
- **注意**：脚本在常规菜单浏览与调优过程中已解耦自动卸载逻辑，不会静默断开宿主机已有的 IPsec 隧道。

---

## 安全卸载与引导回滚

### 完整回滚步骤

```bash
# 1. 清空所有自定义网络优化参数并恢复系统默认
bbr --clean

# 2. 卸载自建 BBRv3 内核并安全回滚 GRUB
bbr --uninstall-kernel

# 3. 重启生效
sudo reboot
```

### 防变砖断言机制
`bbr --uninstall-kernel` 执行时会严格扫描当前系统中是否保留官方 Linux 内核（已全面兼容 Debian 标准包及 Ubuntu 的 `linux-image-unsigned-*` 包）。**若检测到当前系统没有任何官方备用内核，脚本将强制拒绝卸载**，避免机器重启后由于缺少内核而彻底失联。

---

## GitHub Actions 云端与本地构建

本项目自带完整的云端自动化构建流水线与本地构建脱耦支持。

### 1. GitHub Actions 云端自动构建
1. Fork 本仓库至个人 GitHub 账号；
2. 进入仓库 `Settings → Actions → General`，将 **Workflow permissions** 勾选为 **Read and write permissions**；
3. 进入 `Actions → 构建带有BBRv3的内核 → Run workflow`：
   - **`force_rebuild`**：勾选后跳过 Release 存在性检查，强制重新编译；
   - **`kernel_version`**：指定构建的特定 Linux 内核版本（留空则自动跟踪 kernel.org 最新 stable）。
4. 编译完成后，产物会自动生成对应版本的 Release 并附带 `SHA256SUMS` 校验清单。

### 2. 使用自己 Fork 仓库构建的内核
```bash
BBR_REPO="你的用户名/bbr-v3-pro" bbr --install-kernel
```
脚本支持使用 `BBR_REPO` 环境变量，自更新与内核下载均指向您的私有维护仓库，不会被上游主仓库覆盖。

### 3. 本地脱机构建
构建脚本已解除对 GitHub Actions 环境变量的依赖，支持在本地独立机器直接执行配置准备：
```bash
bash scripts/prepare-kernel-config.sh x86_64
# 或
bash scripts/prepare-kernel-config.sh arm64
```

---

## 常见问题解答 (FAQ)

#### Q: 安装内核重启后 `uname -r` 为什么没有变成 `-bbrv3`？
1. **未执行重启**：新内核必须在执行 `sudo reboot` 后由 GRUB 加载生效；
2. **GRUB 默认引导项未更新**：可进入云控制台 VNC 在 GRUB 界面手动选择带有 `-bbrv3` 的项启动，进入系统后执行 `sudo update-grub`；
3. **版本号相同**：当前运行的已经是最新版本的构建包。

#### Q: 在 Debian 12 极简镜像或 Docker 容器内运行提示 `sudo: command not found`？
最新版已全面重构权限控制机制。当您以 `root` 用户身份（UID 为 0）运行脚本时，脚本会自动将 `$SUDO` 置空，不再强行调用 `sudo`，且能完整保留您在当前 shell 中配置的 `http_proxy` 等代理环境变量。

#### Q: 我的 VPS 是 KVM / 搬瓦工 / 腾讯云，开启 Hyper-V 会不会拖慢性能？
**完全不会。** Hyper-V 驱动已被编译为外部内核模块（`=m`）。在 KVM / Xen 架构下，Linux 内核启动时只会按需载入 VirtIO 驱动，Hyper-V 模块静默停留在硬盘中，**内存占用为 0 MB，CPU 消耗为 0%**。

#### Q: 提示"部分运行态参数未被完全采纳"？
部分参数（如极端大的 `net.core.somaxconn` 或低于内核底线的缓冲区）可能会受到内核硬上限限制。脚本的回读校验机制会明确向您指出哪些参数未生效，其余兼容参数已正常生效并落盘。

---

## 目录结构说明

```text
bbr-v3-pro/
├── .github/workflows/
│   ├── build.yml                 # GitHub Actions 云端内核自动化构建与基线同步流水线
│   └── lint.yml                  # ShellCheck 与语法静态检查
├── patches/                      # BBRv3 主线内核移植补丁 (7.0 / 7.1 / 7.2)
├── scripts/
│   ├── apply-bbrv3-port.sh       # 补丁安全版本排序与自动模糊应用
│   ├── apply-bbrv3-max-profile.sh# Max 激进测速参数注入
│   ├── prepare-kernel-config.sh  # 内核编译配置策略注入与自寻址准备
│   └── build-bbrv3-max-kernel.sh # 本地编译辅助脚本
├── arm64.config                  # ARM64 架构内核编译基线配置 (含 Hyper-V 支持)
├── x86-64.config                 # x86_64 架构内核编译基线配置 (含 Hyper-V 支持)
├── cve_2026_31431_detector.py    # CVE-2026-31431 & Dirty Frag 运行态安全检测脚本
├── install.sh                    # 核心管理与网络调优主程序
└── README.md                     # 项目技术文档与使用手册
```

---

## 开源协议

本项目基于 [MIT](LICENSE) 协议开源。
