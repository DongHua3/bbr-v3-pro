# bbr-v3-pro

Linux 服务器网络调优与 BBRv3 主线内核自动化管理系统。一条命令安装 BBRv3 内核并完成 TCP/UDP 双栈调优，附带针对小内存 VPS 的防 OOM 内存钳位保护。

- 支持 Debian 12+ / Ubuntu 22.04+ / Ubuntu 24.04+，x86_64 与 arm64
- 虚拟化全面兼容：KVM（VirtIO）、Microsoft Hyper-V / Azure（VMBus）、Xen、VMware、裸金属
- 交互菜单 + 命令行参数双模式（适合批量 Ansible / cloud-init）
- 无广告、无推广外链、无 Emoji 干扰

---

## 目录

- [它能解决什么问题](#它能解决什么问题)
- [快速开始](#快速开始)
- [新手教程：从零到调优完成](#新手教程从零到调优完成)
- [功能详解](#功能详解)
- [使用场景](#使用场景)
- [如何确认调优生效了](#如何确认调优生效了)
- [卸载与还原](#卸载与还原)
- [自己编译内核](#自己编译内核)
- [常见问题 (FAQ)](#常见问题-faq)
- [已知限制](#已知限制)
- [目录结构](#目录结构)
- [开源协议](#开源协议)

---

## 它能解决什么问题

Linux 服务器默认的网络参数是为通用场景设计的，在高延迟链路、大带宽、或小内存机器上往往不是最优。常见症状：

| 症状 | 原因 | 本工具的对策 |
|---|---|---|
| 跨国传输速度上不去 | 默认拥塞控制（Cubic）把丢包当成拥塞信号 | 编译集成主线 BBRv3 内核，主动探测带宽和延迟 |
| 大文件传输速度慢、忽快忽慢 | 发送缓冲区太小，撑不满带宽时延积 (BDP) | 按带宽和延迟精算并放大缓冲区 |
| 迅雷/下载一开，SSH 就卡 | 缓冲区膨胀（Bufferbloat） | 换 fq / cake 队列算法过滤抖动 |
| 内存小的机器一到晚高峰就重启 | 缓冲区放大过度，把内存吃光触发 OOM | 引入内存安全引擎，按物理内存动态钳位 `tcp_mem` 上限 |
| 装完不知道有没有生效 | 传统脚本写入失败静默吞掉报错 | 写入后自动逐项回读校验断言 |
| 换核重启后开机黑屏死机 (Panic) | 自定义内核缺失特定云平台底层驱动 | 全面开启 12 项 Hyper-V / Azure 驱动矩阵，对齐官方基线 |

> **BBRv3 是什么**：Google 的 BBR 拥塞控制算法第三代实现。它不靠丢包判断拥塞，而是主动测量带宽和延迟来调速，在高丢包的长链路（跨国线路）上通常明显优于默认的 Cubic。本项目把 BBRv3 补丁打进主线内核并编译成可直接安装的 `.deb`。

---

## 快速开始

### 方式一：交互菜单（推荐新手）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh)
```

首次运行会自动装好全局快捷命令 `/usr/local/bin/bbr`，之后在终端直接输入 `bbr` 即可打开控制台。

> ⚠️ 注意：上面这条命令是**一次性执行**，它不会自动更新已装好的快捷命令 `bbr`。  
> 想让 `bbr` 用上最新版，执行 `bbr --update`（见下文）。

### 方式二：命令行参数（适合脚本 / 批量运维）

```bash
# 建议先下载到本地再执行，避免管道中断导致的问题
curl -fsSL -o /tmp/bbr.sh https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh

sudo bash /tmp/bbr.sh --status
```

### 交互菜单一览

输入 `bbr` 打开主菜单，共 13 项（输入编号操作）：

| 编号 | 功能 | 说明 |
|---|---|---|
| 1 | 查看系统网络栈与内核状态 | 含 BBRv3 强校验、内存防 OOM 状态与安全缓解看板 |
| 2 | 安装 / 更新 BBRv3 内核 | 可选标准稳定版或测速 Max 激进版，装完需重启 |
| 3 | 启用 BBR + FQ | 仅调整算法与基础队列，不动缓冲区 |
| 4 | 启用 BBR + CAKE | 抗晚高峰拥堵与 ACK 抖动 |
| 5 | 应用 AI 网关与跨洋全栈优化 | TCP+UDP 全栈大水管，防 OOM 钳位，**大多数 VPS 推荐** |
| 6 | BBR v3 智能带宽动态调优 | 输入实际物理带宽与 RTT 精算 BDP 缓冲区 |
| 7 | 应用亚太短链路低延迟调优 | 香港/日本/新加坡直连线路专属，低延迟优先 |
| 8 | 检查系统 TCP / UDP 端口占用 | 快速排查 80 / 443 / 8443 等常用端口冲突 |
| 9 | 还原系统出厂网络设置 | 清空持久化参数，回退系统默认 |
| 10 | 卸载自建 BBRv3 内核 | 安全校验官方备用内核后回滚 GRUB 引导 |
| 11 | 彻底卸载 bbr-v3-pro | 清空配置、删除快捷命令与临时文件 |
| 12 | **更新 bbr-v3-pro 到最新版** | 一键升级快捷命令，支持识别 Fork 仓库 |
| 0 | 退出管理系统 | 退出当前控制台 |

### 更新与版本

脚本自带语义化版本号，用 `bbr --version` 或 `bbr --status` 查看。

```bash
bbr --version        # bbr-v3-pro v1.4.0
bbr --update         # 一条命令把快捷命令更新到最新版
```

也可以直接打开菜单选 **12**，效果相同。

`--update` 流程：下载最新脚本 → 校验内容确为本项目脚本 → 比较版本 → 覆盖 `/usr/local/bin/bbr` 并恢复权限。版本相同时会提示“已是最新版本”并退出，不做无谓写入。

> **关于 CDN 缓存**：`raw.githubusercontent.com` 的边缘缓存有时不尊重 `Cache-Control: no-cache`，刚发布新版本后可能几分钟内仍返回旧文件。`--update` 会检查版本，若远端版本低于本地会拒绝覆盖。确认要强制覆盖（例如回退版本）：`bbr --update --force`

### 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 12+ / Ubuntu 22.04+ / Ubuntu 24.04+ |
| 架构 | x86_64 / aarch64 (ARM64) |
| 虚拟化 | KVM（VirtIO）、Microsoft Hyper-V / Azure（VMBus）、Xen、VMware |
| 权限 | root（或具有免密 sudo 权限的用户）|
| 包管理 | `apt` |
| 引导 | GRUB（用于内核切换与回滚）|

> 树莓派、NanoPi 等依赖 U-Boot 或厂商定制内核链路的嵌入式设备不建议使用——它们的内核安装和启动流程与通用 VPS 差异较大。

---

## 新手教程：从零到调优完成

### 第 1 步：看看现在什么状态
```bash
sudo bash /tmp/bbr.sh --status
```
输出示例：
```text
==================== BBR 状态与系统体检 ====================
脚本版本       : 1.4.0
系统内核版本   : 6.1.0-50-amd64
TCP 拥塞控制   : cubic
UDP 套接字缓冲 : 8192 KB (系统默认)
队列管理算法   : fq_codel
物理内存状态   : 712 MB (系统默认)
持久化优化配置 : 未加载 (当前运行系统默认参数)
安全缓解状态   : 未启用
```
看到 `TCP 拥塞控制 : cubic` 就说明还没用上 BBR。

### 第 2 步：装 BBRv3 内核
```bash
sudo bash /tmp/bbr.sh --install-kernel
```
脚本会自动下载对应架构的内核 `.deb` 包，校验完整性并配置 GRUB（**不删除旧内核**，原系统安全无忧）。

### 第 3 步：重启服务器
```bash
sudo reboot
```
内核升级必须重启才能载入引导。

### 第 4 步：确认新内核在跑
```bash
uname -r
```
期望看到类似 `7.2.8-bbrv3` 的输出（带有 `-bbrv3` 后缀）。

### 第 5 步：应用调优
不确定选哪个就用推荐的综合方案：
```bash
sudo bash /tmp/bbr.sh --tune=ai-gateway
```
它会同时配置拥塞控制、队列算法、缓冲区大小与内存水位，并按机器物理内存自动钳位防 OOM。

### 第 6 步：确认生效
```bash
sudo bash /tmp/bbr.sh --status
```
期望输出：
```text
TCP 拥塞控制   : bbr (v3)
队列管理算法   : fq
UDP 套接字缓冲 : 16 MB (AI/Hy2 专属大水管)
物理内存状态   : 712 MB (已开启 40% 防 OOM 保护)
持久化优化配置 : 已加载 (/etc/sysctl.d/99-bbr-v3-pro.conf)
```
看到 `bbr (v3)` 且物理内存标注已开启防 OOM 保护，即代表生效。

### 第 7 步：验证重启后不丢失
```bash
sudo reboot
```
再次重连执行 `bbr --status`，若输出保持不变，说明持久化配置已在开机时成功自加载。

---

## 功能详解

### 内核安装与卸载

| 命令 | 作用 |
|---|---|
| `--install-kernel` | 安装/更新最新 BBRv3 标准内核 |
| `--install-kernel=max` | 安装 Max 激进吞吐版（仅限自有链路测速实验）|
| `--uninstall-kernel` | 卸载自建内核，安全回滚至官方备用内核 |

**Max 版说明**：放宽了丢包容忍阈值（`bbr_loss_thresh = 3%`），缩短探测周期，提高了 Startup 阶段 pacing gain。**仅适合自有实验链路测速，公网生产环境请使用标准版。**

### 网络调优预设

| 命令 | 适用场景 | 特点 |
|---|---|---|
| `--apply-bbr` | 生产关键机，只想启用 BBR | 只改算法和队列，不动缓冲区，风险最低 |
| `--tune=ai-gateway` | 大多数跨境 VPS 的默认最佳选择 | TCP+UDP 全栈调优，按内存分档防 OOM |
| `--tune=smart` | 掌握明确物理带宽与延迟 | 按 BDP 公式精算缓冲区 |
| `--tune=apac` | 香港/日本/新加坡等亚太直连 | 紧凑 8MB 缓冲区，低延迟优先 |

**调优预设之间是「替代」而非「叠加」**：
```text
>>> qdisc 段（算法 + 队列）  →  只替换自己，不动 tune 段
>>> tune 段（缓冲区等调优）  →  整体替换，新的预设完全覆盖旧的
```
每次执行调优预设，新的预设会整体替代旧预设中的缓冲区参数。**想要哪套就最后运行哪套。**

### 队列算法与调优预设的关系

`>>> tune` 段只负责缓冲区类参数，不负责队列算法（`default_qdisc` 属于 `>>> qdisc` 段）。
- 调优预设内部为了确保开箱即用，都会顺带执行一次启用 BBR + FQ；
- 因此：**如果你想要 CAKE 队列，在跑完调优预设之后再切一次 CAKE**。

推荐执行顺序：
```text
1. 先跑调优预设（例如菜单 5: --tune=ai-gateway）—— 顺便打开 BBR + FQ
2. 再切队列算法（菜单 4: 启用 BBR + CAKE）—— 这一步生效最终队列
```

需求对照表：
| 业务需求 | 推荐选择 |
|---|---|
| 不确定选哪个，想要综合最优 | `--tune=ai-gateway` |
| 亚太短链路（港/日/新，RTT < 80ms） | `--tune=apac` |
| 明确知道物理带宽和实测延迟 | `--tune=smart` |
| 晚高峰网络波动剧烈、丢包跳 Ping | 跑完调优预设后，选菜单 4 切 CAKE |

### 调优参数明细

`--tune=ai-gateway` 写入以下参数（受物理内存自动钳位）：

```ini
# 算法与队列
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# UDP / QUIC 缓冲区（Hysteria 2、Caddy HTTP/3）
net.core.rmem_max = <按内存分档计算>
net.core.wmem_max = <按内存分档计算>
net.core.netdev_max_backlog = <按内存分档：4096 或 10000>

# TCP 缓冲区与低延迟（VLESS、大模型流式传输）
net.ipv4.tcp_rmem = 4096 87380 <按内存分档计算>
net.ipv4.tcp_wmem = 4096 65536 <按内存分档计算>
net.ipv4.tcp_mem = <按内存 10%/25%/40% 计算页面数>
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
```

**内存自适应与防 OOM 规则**：

| 物理内存 | 单 Socket 缓冲区上限 | 网卡接收队列 |
|---|---|---|
| < 600 MB | 8 MB | 4096 |
| 600 MB ~ 1.5 GB | 16 MB | 4096 |
| > 1.5 GB | 32 MB | 10000 |

三重硬保护：
1. 单 Socket 上限受 `物理内存 × 15%` 硬顶约束；
2. 物理内存 < 256MB 时自动跳过 `tcp_mem` 压缩，避免误缩正常连接；
3. `net.core.somaxconn` 只升不降（若当前系统值已 ≥ 4096 则完全保持不动）。

### 安全防御与 CVE 探测

针对近期 Linux 网络栈安全事件提供纵深防御：

1. **独立 CVE 探测器**：
   ```bash
   python3 cve_2026_31431_detector.py
   ```
   - 包含主动装载防御（防止探测操作本身触发内核自动加载漏洞模块）；
   - 精准检测 `esp4` / `esp6` / `rxrpc` / `algif_aead`，即使缺失 `/boot/config` 亦以运行态真实研判。
2. **安全缓解指令 (`--mitigate-cve`)**：
   ```bash
   bbr --mitigate-cve
   ```
   写入黑名单并尝试卸载高危模块。已与日常菜单交互解耦，**绝不会在浏览菜单时误掐断已有 IPsec VPN 隧道**。

---

## 使用场景

### 场景一：512M / 768M 小内存 VPS 跑代理
1 核 512M，跑 Xray/VLESS 或 Hysteria 2，晚高峰偶尔 OOM。
```bash
sudo bash /tmp/bbr.sh --install-kernel
sudo reboot
sudo bash /tmp/bbr.sh --tune=ai-gateway
```
`ai-gateway` 会将单连接缓冲区钳制在内存 15% 以内，全局 `tcp_mem` 锁在 40% 水位，杜绝内存爆满。

### 场景二：大带宽服务器跑 AI API 网关
4 核 8G，反代 OpenAI/Claude API，需要长连接流式传输。
```bash
sudo bash /tmp/bbr.sh --tune=ai-gateway
```
`tcp_slow_start_after_idle=0` 避免空闲后重置窗口，`tcp_notsent_lowat=16384` 降低首包排队延迟。

### 场景三：亚太短链路（港/日/新）
香港 VPS，国内直连，RTT 30~80ms。
```bash
sudo bash /tmp/bbr.sh --tune=apac
```
紧凑型小缓冲区避免排队，延迟极低。

### 场景四：已知带宽和延迟，想要精确调优
美西 VPS，500Mbps 带宽，国内访问 RTT 约 180ms。
```bash
sudo bash /tmp/bbr.sh --tune=smart
# 提示输入带宽时填 500，选择延迟输入 180
```
按 BDP 公式 `500 × 125000 × 180 / 1000 × 3` 计算精准分配。

### 场景五：只想启用 BBR，不想动系统参数
生产机，不敢修改网络缓冲区。
```bash
sudo bash /tmp/bbr.sh --apply-bbr
```
仅设置 `default_qdisc=fq` 与 `tcp_congestion_control=bbr`，不动任何缓冲区。

### 场景六：晚高峰网络拥堵，需要抗延迟抖动
```bash
sudo bash /tmp/bbr.sh --apply-bbr
# 然后进菜单选第 4 项「启用 BBR + CAKE」
bbr
```
CAKE 自带流隔离与 ACK 过滤，大幅减轻同机多应用竞争时的队头阻塞。

### 场景七：排查端口冲突
```bash
sudo bash /tmp/bbr.sh --check-ports
```
检查 80 / 443 / 8443 等常用端口占用，排查服务启动冲突。

### 场景八：想完全还原，或彻底卸载
```bash
# 只清空网络参数（保留内核与工具）
sudo bash /tmp/bbr.sh --clean

# 彻底卸载工具与所有配置
sudo bash /tmp/bbr.sh --uninstall-all
```

---

## 如何确认调优生效了

**第一步：看运行态**
```bash
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
sysctl net.core.rmem_max net.ipv4.tcp_rmem
```

**第二步：看持久化配置**
```bash
cat /etc/sysctl.d/99-bbr-v3-pro.conf
```
正常应包含两对清晰的段标记：
```ini
# >>> qdisc
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# <<< qdisc
# >>> tune
...
# <<< tune
```

**第三步：确认网卡出口实际生效队列**
```bash
tc qdisc show dev $(ip route show default | awk '{print $5; exit}')
```

---

## 卸载与还原

### 完整回滚步骤
```bash
# 1. 还原网络配置
sudo bash /tmp/bbr.sh --clean

# 2. 卸载 BBRv3 内核，回滚到官方内核
sudo bash /tmp/bbr.sh --uninstall-kernel

# 3. 重启生效
sudo reboot
```

### 防变砖断言保护
`--uninstall-kernel` 在删除前会严格检测系统是否保留官方备用内核（支持匹配 Debian 标准包及 Ubuntu 的 `linux-image-unsigned-*`）。若检测到无备用内核，**将坚决拦截卸载**，避免机器重启后因无内核变砖失联。

---

## 自己编译内核

项目内置完整的 GitHub Actions 云端构建流水线与本地脱机构建支持。

### 云端自动构建
1. Fork 本仓库至个人 GitHub 账号；
2. 进入 `Settings → Actions → General`，将 Workflow permissions 设为 **Read and write permissions**；
3. 进入 `Actions → 构建带有BBRv3的内核 → Run workflow`：
   - `force_rebuild`：勾选后跳过 Release 存在性检查，强制重新编译；
   - `kernel_version`：输入指定内核版本（留空默认拉取最新 stable）。
4. 编译完成后产物会自动发布至 Releases。

使用自有内核：
```bash
BBR_REPO="你的用户名/bbr-v3-pro" sudo bash /tmp/bbr.sh --install-kernel
```

### 本地脱机构建
构建脚本支持本地目录自寻址，无需依赖 GitHub Actions 环境变量：
```bash
bash scripts/prepare-kernel-config.sh x86_64
# 或
bash scripts/prepare-kernel-config.sh arm64
```

---

## 常见问题 (FAQ)

### 装完 `uname -r` 没变化？
1. **没重启** —— 内核必须重启后由 GRUB 加载生效；
2. **GRUB 引导项未切** —— 在云控制台 VNC 中手动选择带 `-bbrv3` 的条目启动，进入系统后执行 `sudo update-grub`；
3. **版本相同** —— 提示内核映像未发生变化，说明当前已在跑最新版。

### 报“内核拒绝写入 xxx”或“xxx 未被完全采纳”？
说明该参数受当前内核硬上限限制。脚本的回读校验会列出未生效项，**这不影响其余兼容参数正常生效**。

### `--clean` 之后参数还在？
正常。`--clean` 只删除持久化配置文件，**已经写入内核的运行态值不会自动消失**，重启后恢复系统默认。

### 快捷命令 `bbr` 会不会自动更新？
**不会。** 它是首次安装时缓存的本地副本，保证离线可用与快速启动。需要时执行：
```bash
bbr --update
```

### 怎么知道我的 `bbr` 是不是最新版？
```bash
bbr --version
```
对比 GitHub 仓库的 `install.sh` 里的 `BBR_SCRIPT_VERSION` 即可。`bbr --status` 也会显示版本。

### 每次重新执行那条 `bash <(curl ...)` 命令，要重新给执行权限吗？
**不需要。** `chmod` 改的是文件属性，设置一次永久保留。通过 `bash /usr/local/bin/bbr` 调用只需要读权限。

### 在 Debian 12 极简镜像运行提示 `sudo: command not found`？
最新版已重构权限判定。当您以 `root` 用户身份运行时，脚本会自动将 `$SUDO` 置空，不再强行调用 `sudo`，且能完整保留您当前 shell 的代理环境变量。

### 我的 VPS 是 KVM 架构，开启 Hyper-V 会不会拖慢性能？
**完全不会。** Hyper-V 驱动被编译为外部内核模块（`=m`）。在 KVM / Xen 架构下，Linux 内核自检只会加载 VirtIO 驱动，Hyper-V 模块静默停留在磁盘中，**内存占用为 0 MB，CPU 消耗为 0%**。

### 支持 Alpine / CentOS / 其它发行版吗？
**不支持。** 内核产物为 `.deb`，流程依赖 Debian/Ubuntu 的包管理和 GRUB 链路。

---

## 已知限制

诚实说明，避免踩坑：

1. **主要验证环境**：核心流程在 Debian 12 / Ubuntu 24.04、x86_64 及 ARM64 架构、主流 KVM / Hyper-V 云平台上验证通过。极端极小内存（<128MB）暂未做深度压力测试。
2. **不支持回退到历史旧版内核**：脚本默认安装最新发布的 Release。如需回退，请在 Releases 页面手动下载旧版 `.deb` 安装。
3. **不支持非 Debian 系发行版**（如 RHEL、Alpine、Arch）。

### 已实机验证的功能

以下功能均在真实环境或端到端测试套件中经过验证：

| 功能 | 验证内容 |
|---|---|
| `--status` | 状态体检、版本展示、准确识别 BBRv3 / BBRv1 |
| `--install-kernel` | 内核下载、哈希比对、安装路径、同版本拦截 |
| `--apply-bbr` | 算法与队列切换、持久化保存 |
| 菜单 4 | 切换 CAKE 队列，网卡出口实际生效队列回读 |
| `--tune=ai-gateway` | 全栈调优、内存分档、防 OOM 页面池钳位 |
| `--tune=apac` | 亚太短链路预设、BBR+FQ 联动与回读闭环 |
| `--tune=smart` | BDP 动态公式计算与参数注入 |
| `--mitigate-cve` | 显式写入安全规则，解耦菜单自动卸载保护 IPsec |
| `--check-ports` | 端口占用探测 |
| `--clean` | 清空配置 + 运行态残留参数提醒 |
| `--uninstall-kernel` | 防变砖断言（正确识别官方内核后才允许卸载）|
| 重启持久化 | 重启后参数与配置自动恢复 |
| 快捷命令 | 自更新、`--version` 正常工作 |

---

## 目录结构

```text
bbr-v3-pro/
├── .github/workflows/
│   ├── build.yml                 # 云端构建与基线回写工作流
│   └── lint.yml                  # 静态语法与格式检查
├── patches/                      # BBRv3 主线内核移植补丁 (7.0 / 7.1 / 7.2)
├── scripts/
│   ├── apply-bbrv3-port.sh       # 补丁安全版本排序 (sort -V) 与模糊匹配
│   ├── apply-bbrv3-max-profile.sh# Max 激进测速参数注入
│   ├── prepare-kernel-config.sh  # 内核配置策略注入与自寻址准备
│   └── build-bbrv3-max-kernel.sh # 本地编译辅助脚本
├── tests/                        # 自动化回归与端到端测试套件 (174 项用例)
├── arm64.config                  # ARM64 内核配置 (含 12 项 Hyper-V 驱动)
├── x86-64.config                 # x86_64 内核配置 (含 12 项 Hyper-V 驱动)
├── cve_2026_31431_detector.py    # 运行态 CVE 检测脚本 (防主动装载)
├── install.sh                    # 核心管理脚本 (v1.4.0)
├── LICENSE                       # MIT 开源协议
└── README.md                     # 完整技术手册与使用指南
```

---

## 开源协议

本项目基于 [MIT](LICENSE) 协议开源。
