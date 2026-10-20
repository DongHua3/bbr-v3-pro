# bbr-v3-pro

Linux 服务器网络调优与 BBRv3 主线内核自动化管理系统。一条命令装好 BBRv3 内核并完成 TCP/UDP 双栈调优，附带面向小内存 VPS 的防 OOM 内存钳位。

- 支持 Debian 12+ / Ubuntu 22.04+ / Ubuntu 24.04+，x86_64 与 arm64
- 虚拟化兼容 KVM（VirtIO）、Hyper-V / Azure（VMBus）、Xen、VMware 与裸金属
- 交互菜单与命令行参数双模式，可对接 Ansible / cloud-init 批量下发
- 无广告、无推广外链、无 Emoji

---

## 目录

- [这个项目解决什么问题](#这个项目解决什么问题)
- [快速开始](#快速开始)
- [命令速查](#命令速查)
- [交互菜单](#交互菜单)
- [调优预设怎么选](#调优预设怎么选)
- [参数与内存策略](#参数与内存策略)
- [内核安全与 CVE 探测](#内核安全与-cve-探测)
- [使用场景](#使用场景)
- [验证调优是否生效](#验证调优是否生效)
- [卸载与还原](#卸载与还原)
- [自己编译内核](#自己编译内核)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [目录结构](#目录结构)
- [开源协议](#开源协议)

---

## 这个项目解决什么问题

Linux 默认的网络参数是为通用场景调的，在高延迟链路、大带宽或小内存机器上往往不是最优。典型症状与对应解法：

| 症状 | 根因 | 本项目的对策 |
|---|---|---|
| 跨国传输速度上不去 | 默认拥塞控制 Cubic 把丢包当成拥塞信号 | 集成主线 BBRv3 内核，主动测量带宽与延迟 |
| 大文件传输忽快忽慢 | 发送缓冲区太小，撑不满带宽时延积（BDP） | 按带宽与延迟精算并放大缓冲区 |
| 下载一开，SSH 就卡 | 缓冲区膨胀（Bufferbloat） | 换用 fq / cake 队列算法过滤抖动 |
| 小内存机器晚高峰重启 | 缓冲区放大过度吃光内存，触发 OOM | 内存安全引擎按物理内存动态钳位 `tcp_mem` |
| 装完不知道有没有生效 | 传统脚本写入失败时静默吞掉报错 | 写入后逐项回读校验并断言 |
| 换核重启后黑屏死机 | 自定义内核缺失云平台底层驱动 | 开启 12 项 Hyper-V / Azure 驱动矩阵，对齐官方基线 |

**BBRv3 是什么**：Google BBR 拥塞控制算法的第三代实现。它不靠丢包判断拥塞，而是主动测量带宽和延迟来调速，在高丢包的长链路上通常明显优于默认的 Cubic。本项目把 BBRv3 补丁打进主线内核，编译成可直接安装的 `.deb`。

---

## 快速开始

### 一条命令装好

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh)
```

首次运行会自动安装全局快捷命令 `/usr/local/bin/bbr`，之后在终端输入 `bbr` 即可打开控制台。

> 这条命令是**一次性执行**，不会更新已装好的快捷命令。想让 `bbr` 用上最新版，执行 `bbr --update`。

### 脚本模式（批量 / 离线）

```bash
# 建议先下载到本地再执行，避免管道中断
curl -fsSL -o /tmp/bbr.sh https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh

sudo bash /tmp/bbr.sh --status
```

### 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 12+ / Ubuntu 22.04+ / Ubuntu 24.04+ |
| 架构 | x86_64 / aarch64 (ARM64) |
| 虚拟化 | KVM（VirtIO）、Hyper-V / Azure（VMBus）、Xen、VMware |
| 权限 | root，或具有免密 sudo 权限的用户 |
| 包管理 | `apt` |
| 引导 | GRUB（用于内核切换与回滚） |

树莓派、NanoPi 等依赖 U-Boot 或厂商定制内核链路的嵌入式设备不建议使用——它们的安装与启动流程与通用 VPS 差异过大。

### 首次使用三步走

**1. 看现状**

```bash
sudo bash /tmp/bbr.sh --status
```

```text
==================== BBR 状态与系统体检 ====================
脚本版本       : 2.0.2
系统内核版本   : 6.1.0-50-amd64
TCP 拥塞控制   : cubic
UDP 套接字缓冲 : 8192 KB (系统默认)
队列管理算法   : fq_codel
物理内存状态   : 712 MB (系统默认)
持久化优化配置 : 未加载 (当前运行系统默认参数)
安全缓解状态   : 未启用
```

看到 `TCP 拥塞控制 : cubic`，说明还没用上 BBR。

**2. 装内核并重启**

```bash
sudo bash /tmp/bbr.sh --install-kernel
sudo reboot
```

安装过程会自动下载对应架构的 `.deb`、校验完整性并写入 GRUB。**旧内核不会被删除**，随时可回退。

重启后确认：

```bash
uname -r          # 期望看到 7.3.x-bbrv3 这样的输出
```

**3. 应用调优**

```bash
sudo bash /tmp/bbr.sh --tune=ai-gateway
```

不确定选哪个就用这一套。它会同时配置拥塞控制、队列算法、缓冲区与内存水位，并按物理内存自动钳位防 OOM。

再次执行 `--status`，期望看到：

```text
TCP 拥塞控制   : bbr (v3)
队列管理算法   : fq
UDP 套接字缓冲 : 16 MB (AI/Hy2 专属大水管)
物理内存状态   : 712 MB (已开启 40% 防 OOM 保护)
持久化优化配置 : 已加载 (/etc/sysctl.d/99-bbr-v3-pro.conf)
```

重启一次，重连后再看，输出不变即说明持久化配置已能开机自加载。

---

## 命令速查

| 想做什么 | 命令 |
|---|---|
| 看状态与体检 | `--status` |
| 装 / 升级 BBRv3 内核 | `--install-kernel` |
| 只启用 BBR，不动缓冲区 | `--apply-bbr` |
| 综合调优（推荐） | `--tune=ai-gateway` |
| 按实测带宽延迟精算 | `--tune=smart` |
| 亚太低延迟线路 | `--tune=apac` |
| 排查端口占用 | `--check-ports` |
| 清空网络参数 | `--clean` |
| 卸载自建内核 | `--uninstall-kernel` |
| 彻底卸载工具 | `--uninstall-all` |
| 更新脚本本体 | `--update` |
| 查看版本 | `--version` |
| CVE 缓解 | `--mitigate-cve` |

以上命令均需 root 权限执行，例如 `sudo bash /tmp/bbr.sh --status`；已装好快捷命令的可直接用 `bbr --status`。

---

## 交互菜单

输入 `bbr` 打开主菜单，共 13 项，输入编号执行：

| 编号 | 功能 | 说明 |
|---|---|---|
| 1 | 查看系统网络栈与内核状态 | 含 BBRv3 强校验、内存防 OOM 状态与安全缓解看板 |
| 2 | 安装 / 更新 BBRv3 内核 | 自动拉取适配系统的最新内核，装完需重启 |
| 3 | 启用 BBR + FQ | 只调算法与基础队列，不动缓冲区 |
| 4 | 启用 BBR + CAKE | 抗晚高峰拥堵与 ACK 抖动 |
| 5 | 应用 AI 网关与跨洋全栈优化 | TCP+UDP 全栈大水管，防 OOM 钳位，**大多数 VPS 推荐** |
| 6 | BBR v3 智能带宽动态调优 | 按物理带宽与 RTT 精算 BDP 缓冲区 |
| 7 | 应用亚太短链路低延迟调优 | 港 / 日 / 新直连线路，低延迟优先 |
| 8 | 检查 TCP / UDP 端口占用 | 排查 80 / 443 / 8443 等常用端口冲突 |
| 9 | 还原系统出厂网络设置 | 清空持久化参数，回退系统默认 |
| 10 | 卸载自建 BBRv3 内核 | 校验官方备用内核后回滚 GRUB 引导 |
| 11 | 彻底卸载 bbr-v3-pro | 清空配置、删除快捷命令与临时文件 |
| 12 | 更新 bbr-v3-pro 到最新版 | 一键升级快捷命令，支持识别 Fork 仓库 |
| 0 | 退出管理系统 | 退出当前控制台 |

### 更新与版本

```bash
bbr --version        # bbr-v3-pro v2.0.2
bbr --update         # 把快捷命令更新到最新版
```

菜单第 12 项效果相同。`--update` 的流程是：下载最新脚本 → 校验内容确为本项目 → 比较版本 → 覆盖 `/usr/local/bin/bbr` 并恢复权限。版本相同时提示「已是最新版本」并退出，不做无谓写入。

**关于 CDN 缓存**：`raw.githubusercontent.com` 的边缘缓存有时不遵守 `Cache-Control: no-cache`，刚发布后几分钟内可能仍返回旧文件。`--update` 会比对版本，远端低于本地时拒绝覆盖；确认要强制覆盖（例如回退版本）用：

```bash
bbr --update --force
```

---

## 调优预设怎么选

| 命令 | 适用场景 | 特点 |
|---|---|---|
| `--apply-bbr` | 生产关键机，只想启用 BBR | 只改算法和队列，不动缓冲区，风险最低 |
| `--tune=ai-gateway` | 大多数跨境 VPS 的默认选择 | TCP+UDP 全栈调优，按内存分档防 OOM |
| `--tune=smart` | 已掌握明确物理带宽与延迟 | 按 BDP 公式精算缓冲区 |
| `--tune=apac` | 港 / 日 / 新等亚太直连 | 紧凑 8MB 缓冲区，低延迟优先 |

### 预设之间是替代，不是叠加

```text
>>> qdisc 段（算法 + 队列）  →  只替换自己，不动 tune 段
>>> tune 段（缓冲区等调优）  →  整体替换，新预设完全覆盖旧预设
```

每次执行调优预设，新的参数会整体替换旧的缓冲区参数。**想要哪套，就最后运行哪套。**

### 队列算法与预设的关系

`>>> tune` 段只负责缓冲区参数，队列算法属于 `>>> qdisc` 段：

- 调优预设为了开箱即用，内部都会顺带执行一次「启用 BBR + FQ」；
- 因此**如果你要 CAKE，请在跑完调优预设之后再切一次**。

推荐顺序：

```text
1. 先跑调优预设（如菜单 5：--tune=ai-gateway）—— 顺便打开 BBR + FQ
2. 再切队列算法（菜单 4：启用 BBR + CAKE）—— 这一步决定最终队列
```

### 按需求选

| 需求 | 选择 |
|---|---|
| 不确定，想要综合最优 | `--tune=ai-gateway` |
| 亚太短链路（港 / 日 / 新，RTT < 80ms） | `--tune=apac` |
| 已知物理带宽与实测延迟 | `--tune=smart` |
| 晚高峰波动剧烈、丢包跳 Ping | 先跑调优预设，再用菜单 4 切 CAKE |

---

## 参数与内存策略

### `--tune=ai-gateway` 写入的参数

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
net.ipv4.tcp_mem = <按物理内存 10% / 25% / 40% 计算页面数>
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
```

### 内存自适应分档

| 物理内存 | 单 Socket 缓冲区上限 | 网卡接收队列 |
|---|---|---|
| < 600 MB | 8 MB | 4096 |
| 600 MB ~ 1.5 GB | 16 MB | 4096 |
| > 1.5 GB | 32 MB | 10000 |

### 三重硬保护

1. 单 Socket 上限受 `物理内存 × 15%` 硬顶约束；
2. 物理内存 < 256 MB 时跳过 `tcp_mem` 压缩，避免误缩正常连接；
3. `net.core.somaxconn` 只升不降（当前值已 ≥ 4096 时完全保持不动）。

---

## 内核安全与 CVE 探测

针对近期 Linux 网络栈安全事件提供纵深防御：

**独立 CVE 探测器**

```bash
python3 cve_2026_31431_detector.py
```

- 含主动装载防御，避免探测动作本身触发内核自动加载漏洞模块；
- 精准检测 `esp4` / `esp6` / `rxrpc` / `algif_aead`，即使缺少 `/boot/config` 也按运行态真实研判。

**安全缓解指令**

```bash
bbr --mitigate-cve
```

写入黑名单并尝试卸载高危模块。该动作已与日常菜单交互解耦，**浏览菜单不会误掐断已有的 IPsec VPN 隧道**。

---

## 使用场景

### 小内存 VPS 跑代理（1 核 512M）

跑 Xray/VLESS 或 Hysteria 2，晚高峰偶尔 OOM。

```bash
sudo bash /tmp/bbr.sh --install-kernel
sudo reboot
sudo bash /tmp/bbr.sh --tune=ai-gateway
```

`ai-gateway` 把单连接缓冲区钳制在物理内存 15% 以内，全局 `tcp_mem` 锁在 40% 水位。

### 大带宽服务器跑 AI API 网关（4 核 8G）

反代 OpenAI / Claude API，需要长连接流式传输。

```bash
sudo bash /tmp/bbr.sh --tune=ai-gateway
```

`tcp_slow_start_after_idle=0` 避免空闲后重置窗口，`tcp_notsent_lowat=16384` 降低首包排队延迟。

### 亚太短链路（港 / 日 / 新，RTT 30~80ms）

```bash
sudo bash /tmp/bbr.sh --tune=apac
```

紧凑型小缓冲区避免排队，延迟优先。

### 已知带宽与延迟，想要精确调优

美西 VPS，500 Mbps 带宽，国内访问 RTT 约 180ms：

```bash
sudo bash /tmp/bbr.sh --tune=smart
# 提示输入带宽时填 500，延迟填 180
```

按 `500 × 125000 × 180 / 1000 × 3` 计算分配。

### 其余常见任务

| 目标 | 做法 |
|---|---|
| 只启用 BBR，不动任何缓冲区 | `sudo bash /tmp/bbr.sh --apply-bbr` |
| 抗晚高峰抖动 | 先 `--apply-bbr`，再进菜单选第 4 项切 CAKE |
| 排查端口冲突 | `sudo bash /tmp/bbr.sh --check-ports` |
| 只清空网络参数（保留内核与工具） | `sudo bash /tmp/bbr.sh --clean` |
| 彻底卸载工具与所有配置 | `sudo bash /tmp/bbr.sh --uninstall-all` |

---

## 验证调优是否生效

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

**第三步：确认网卡出口实际生效的队列**

```bash
tc qdisc show dev $(ip route show default | awk '{print $5; exit}')
```

---

## 卸载与还原

### 完整回滚

```bash
# 1. 还原网络配置
sudo bash /tmp/bbr.sh --clean

# 2. 卸载 BBRv3 内核，回滚到官方内核
sudo bash /tmp/bbr.sh --uninstall-kernel

# 3. 重启生效
sudo reboot
```

### 防变砖断言

`--uninstall-kernel` 在删除前会严格检测系统是否仍保留官方备用内核（匹配 Debian 标准包及 Ubuntu 的 `linux-image-unsigned-*`）。一旦检测不到备用内核，**坚决拦截卸载**，避免重启后无内核可启、机器失联。

---

## 自己编译内核

项目自带完整的 GitHub Actions 云端构建流水线与本地脱机构建支持。

### 云端自动构建

1. Fork 本仓库到自己的 GitHub 账号；
2. 在 `Settings → Actions → General` 把 Workflow permissions 设为 **Read and write permissions**；
3. 进入 `Actions → 构建带有BBRv3的内核 → Run workflow`：
   - `force_rebuild`：勾选后跳过 Release 存在性检查，强制重编；
   - `kernel_version`：指定内核版本，留空则取 kernel.org 的最新 stable。
4. 编译完成后自动发布到 Releases，x86_64 与 arm64 各一个。

编译完成后，安装自有内核：

```bash
BBR_REPO="你的用户名/bbr-v3-pro" sudo bash /tmp/bbr.sh --install-kernel
```

> 单次构建约 80~100 分钟。两个架构并行编译、各自独立发布，先完成的先上线。

### 本地脱机构建

```bash
# 1. 克隆内核源码（以 7.2.y 为例，仓库需有对应版本的 patches/bbrv3-linux-X.Y.patch）
git clone --depth=1 --branch linux-7.2.y https://github.com/gregkh/linux.git kernel/linux
cd kernel/linux

# 2. 应用 BBRv3 移植补丁
bash ../../scripts/apply-bbrv3-port.sh

# 3. 准备编译配置（自动注入调优策略并校验 12 项 Hyper-V 驱动）
bash ../../scripts/prepare-kernel-config.sh x86_64   # ARM64 机器传 arm64

# 4. 多核并行编译，产出 Debian 安装包
make bindeb-pkg -j$(nproc) LOCALVERSION=-bbrv3 KDEB_COMPRESS=gzip skipdbg=true
```

> **大版本刚发布时取不到源码？** `linux-X.Y.y` 稳定分支要等该系列的第一个稳定更新（X.Y.1）进入队列才会建立。例如 7.3 发布后数日内，`gregkh/linux` 里还只有到 `linux-7.2.y`。此时改用 torvalds 仓库的同版本发布标签即可：
>
> ```bash
> git clone --depth=1 --branch v7.3 https://github.com/torvalds/linux.git kernel/linux
> ```

### 补丁来源与升级注意

`patches/` 中的 BBRv3 代码源自 Google 的 BBR 团队，官方发布在 [google/bbr](https://github.com/google/bbr) 的 `v3` 分支（GPLv2 / BSD 双许可）。Google 给出的是整棵内核源码树而非 `.patch`，本项目把它整理成可直接 `git apply` 的补丁，并按内核大版本逐个对齐上下文（7.0 / 7.1 / 7.2 / 7.3）。

补丁里还含一层为适配 Linux 主线而写的兼容代码，这部分不属于 Google 原版：Google 分支依赖的 `tcp_ecn_mode_any()` 在此改写为内联判断，`.cwnd_event_tx_start` 回调则通过 `struct tcp_congestion_ops` 补进主线头文件。

因此**升级内核大版本时补丁必须重新对齐**，不能直接复用。若 `patches/bbrv3-linux-<新版本>.patch` 不存在，脚本会回退到版本号最大的旧补丁并打印提示，但上下文是否仍然吻合并无保证。

---

## 常见问题

### 装完 `uname -r` 没变化？

1. **没重启** —— 内核必须重启后由 GRUB 加载；
2. **GRUB 引导项未切** —— 在云控制台 VNC 里手动选带 `-bbrv3` 的条目，进系统后执行 `sudo update-grub`；
3. **版本相同** —— 提示内核映像未变化，说明已经在跑最新版。

### 提示「内核拒绝写入 xxx」或「xxx 未被完全采纳」？

说明该参数触到了当前内核的硬上限。回读校验会列出未生效项，**不影响其余兼容参数正常生效**。

### `--clean` 之后参数还在？

正常。`--clean` 只删持久化配置文件，**已写入内核的运行态值不会自动消失**，重启后恢复系统默认。

### 快捷命令 `bbr` 会自动更新吗？

**不会。** 它是首次安装时缓存的本地副本，保证离线可用与启动速度。需要时执行 `bbr --update`。

### 怎么知道 `bbr` 是不是最新版？

```bash
bbr --version
```

与仓库 `install.sh` 里的 `BBR_SCRIPT_VERSION` 对比即可，`bbr --status` 也会显示版本。

### 每次重新执行那条 `bash <(curl ...)`，要重新给执行权限吗？

**不需要。** `chmod` 改的是文件属性，设一次永久保留；用 `bash /usr/local/bin/bbr` 调用只需要读权限。

### Debian 12 极简镜像提示 `sudo: command not found`？

最新版已重构权限判定：以 `root` 身份运行时自动将 `$SUDO` 置空，不再强行调用 `sudo`，并完整保留当前 shell 的代理环境变量。

### KVM 机器上开启 Hyper-V 驱动会拖慢性能吗？

**不会。** Hyper-V 驱动被编译为外部模块（`=m`）。在 KVM / Xen 下，内核自检只会加载 VirtIO 驱动，Hyper-V 模块静默留在磁盘上，内存占用 0 MB、CPU 消耗 0%。

### 支持 Alpine / CentOS / 其它发行版吗？

**不支持。** 产物是 `.deb`，流程依赖 Debian/Ubuntu 的包管理与 GRUB 链路。

---

## 已知限制

1. **主要验证环境**：Debian 12 / Ubuntu 24.04，x86_64 与 ARM64，主流 KVM / Hyper-V 云平台。极小内存（< 128MB）尚未做深度压测。
2. **不支持回退到历史旧版内核**：脚本默认安装最新 Release。需要旧版请到 Releases 页面手动下载 `.deb`。
3. **不支持非 Debian 系发行版**（RHEL、Alpine、Arch 等）。

### 已实机验证的功能

| 功能 | 验证内容 |
|---|---|
| `--status` | 状态体检、版本展示、准确区分 BBRv3 / BBRv1 |
| `--install-kernel` | 下载、哈希比对、安装路径、同版本拦截 |
| `--apply-bbr` | 算法与队列切换、持久化保存 |
| 菜单 4 | 切换 CAKE，网卡出口实际生效队列回读 |
| `--tune=ai-gateway` | 全栈调优、内存分档、防 OOM 页面池钳位 |
| `--tune=apac` | 亚太预设、BBR+FQ 联动与回读闭环 |
| `--tune=smart` | BDP 动态公式计算与参数注入 |
| `--mitigate-cve` | 显式写入安全规则，菜单交互与卸载解耦 |
| `--check-ports` | 端口占用探测 |
| `--clean` | 清空配置 + 运行态残留提醒 |
| `--uninstall-kernel` | 防变砖断言（识别到官方内核才允许卸载） |
| 重启持久化 | 重启后参数与配置自动恢复 |
| 快捷命令 | 自更新与 `--version` 正常 |

---

## 目录结构

```text
bbr-v3-pro/
├── .github/workflows/
│   ├── build.yml                 # 云端构建与基线回写工作流
│   └── lint.yml                  # 静态语法与格式检查
├── patches/                      # BBRv3 主线内核移植补丁 (7.0 / 7.1 / 7.2 / 7.3)
├── scripts/
│   ├── apply-bbrv3-port.sh       # 补丁版本排序 (sort -V) 与模糊匹配兜底
│   └── prepare-kernel-config.sh  # 内核配置策略注入与自寻址准备
├── tests/                        # 自动化回归与端到端测试套件 (176 项用例)
├── arm64.config                  # ARM64 内核配置 (含 12 项 Hyper-V 驱动)
├── x86-64.config                 # x86_64 内核配置 (含 12 项 Hyper-V 驱动)
├── cve_2026_31431_detector.py    # 运行态 CVE 检测脚本 (防主动装载)
├── install.sh                    # 核心管理脚本 (v2.0.2)
├── LICENSE                       # MIT 开源协议
└── README.md                     # 完整技术手册与使用指南
```

---

## 开源协议

本项目基于 [MIT](LICENSE) 协议开源。
