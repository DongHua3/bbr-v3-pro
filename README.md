# bbr-v3-pro

Linux 服务器网络调优与 BBRv3 内核管理系统。一条命令装好 BBRv3 内核并完成 TCP/UDP 双栈调优，附带针对小内存 VPS 的防 OOM 保护。

- 支持 Debian 12+ / Ubuntu 22.04+，x86_64 与 arm64
- 交互菜单 + 命令行参数双模式
- 无广告、无推广外链、无 Emoji

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
- [常见问题](#常见问题)
- [已知限制](#已知限制)

---

## 它能解决什么问题

Linux 服务器默认的网络参数是为通用场景设计的，在高延迟链路、大带宽、或小内存机器上往往不是最优。常见症状：

| 症状 | 原因 | 本工具的对策 |
|---|---|---|
| 跨国传输速度上不去 | 默认拥塞控制（Cubic）把丢包当成拥塞信号 | 装 BBRv3 内核 |
| 大文件传输速度慢、忽快忽慢 | 发送缓冲区太小，撑不满带宽时延积 | 按带宽和延迟计算并放大缓冲区 |
| 迅雷/下载一开，SSH 就卡 | 缓冲区膨胀（bufferbloat） | 换 fq / cake 队列算法 |
| 内存小的机器一到晚高峰就重启 | 缓冲区放大过度，把内存吃光触发 OOM | 按物理内存动态钳位缓冲区上限 |
| 装完不知道有没有生效 | 参数写失败也不报错 | 写入后逐项回读校验 |

> **BBRv3 是什么**：Google 的 BBR 拥塞控制算法第三代实现。它不靠丢包判断拥塞，而是主动测量带宽和延迟来调速，在高丢包的长链路（跨国线路）上通常明显优于默认的 Cubic。本项目把 BBRv3 补丁打进主线内核并编译成可直接安装的 `.deb`。

---

## 快速开始

### 方式一：交互菜单（推荐新手）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh)
```

首次运行会自动装好快捷命令，之后直接输入 `bbr` 就能打开菜单。

> ⚠️ 注意：上面这条命令是**一次性执行**，它不会更新已装好的快捷命令 `bbr`。
> 想让 `bbr` 用上最新版，执行 `bbr --update`（见下）。

### 方式二：命令行参数（适合脚本 / 批量运维）

```bash
# 建议先下载到本地再执行，避免管道中断导致的问题
curl -fsSL -o /tmp/bbr.sh https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh

sudo bash /tmp/bbr.sh --status
```

### 交互菜单一览

输入 `bbr` 打开菜单，共 13 项（输入编号操作）：

| 编号 | 功能 |
|---|---|
| 1 | 查看系统网络栈与内核状态（含 BBRv3 检测）|
| 2 | 安装 / 更新 BBRv3 内核（可选标准版或 Max 版）|
| 3 | 启用 BBR + FQ |
| 4 | 启用 BBR + CAKE（抗晚高峰拥堵）|
| 5 | 应用 AI 网关与跨洋全栈优化 |
| 6 | BBR v3 智能带宽动态调优 |
| 7 | 应用亚太短链路低延迟调优 |
| 8 | 检查系统 TCP / UDP 端口占用 |
| 9 | 还原系统出厂网络设置 |
| 10 | 卸载自建 BBRv3 内核 |
| 11 | 彻底卸载 bbr-v3-pro |
| 12 | **更新 bbr-v3-pro 到最新版** |
| 0 | 退出管理系统 |

> 菜单顶部会显示当前脚本版本与系统状态，便于确认是否已是最新。

### 更新与版本

脚本自带版本号，用 `bbr --version` 或 `bbr --status` 查看。

```bash
bbr --version        # bbr-v3-pro v1.2.0
bbr --update          # 一条命令把快捷命令更新到最新版
```

也可以直接打开菜单选 **12**，效果相同。

`--update` 会：下载最新脚本 → 校验内容确为本项目脚本 → 比较版本 → 覆盖 `/usr/local/bin/bbr` 并恢复权限。

版本相同时会提示"已是最新版本"并退出，不做无谓写入。

> **关于 CDN 缓存**：`raw.githubusercontent.com` 的边缘缓存不尊重 `Cache-Control: no-cache`，刚发布新版本后可能几分钟内仍返回旧文件。`--update` 已处理这种情况——若远端版本**低于**本地，会拒绝覆盖并提示，避免把新脚本降级成旧版。
>
> 确认要强制覆盖（例如回退版本）时：`bbr --update --force`

### 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 12+ / Ubuntu 22.04+ |
| 架构 | x86_64 / aarch64 |
| 权限 | root |
| 包管理 | `apt` |
| 引导 | 建议 GRUB（用于内核切换）|

> 树莓派、NanoPi 等依赖 U-Boot 或厂商定制内核链路的设备不建议使用——它们的内核安装和启动流程与通用 VPS 差异较大。

---

## 新手教程：从零到调优完成

### 第 1 步：看看现在什么状态

```bash
sudo bash /tmp/bbr.sh --status
```

输出示例：

```
==================== BBR 状态与系统体检 ====================
脚本版本       : 1.1.1
系统内核版本   : 6.1.0-50-amd64
TCP 拥塞控制   : cubic
UDP 套接字缓冲 : 8192 KB (系统默认)
队列管理算法   : fq_codel
物理内存状态   : 712 MB (系统默认)
持久化优化配置 : 未加载 (当前运行系统默认参数)
安全缓解状态   : 已启用 (esp4/esp6/rxrpc/algif_aead 黑名单)
```

看到 `TCP 拥塞控制 : cubic` 就说明还没用上 BBR。

### 第 2 步：装 BBRv3 内核

```bash
sudo bash /tmp/bbr.sh --install-kernel
```

脚本会：

1. 从 Release 下载匹配架构的内核 `.deb` 包
2. 校验安装包完整性（Release 附带 `SHA256SUMS` 时逐包比对哈希）
3. 安装新内核（**不删除旧内核**，失败时原系统完好）
4. 更新 GRUB 引导

**如果提示"当前内核版本与要安装的版本相同"，说明你已经装过了**，可以跳过这步。

### 第 3 步：重启

```bash
sudo reboot
```

内核必须重启才能生效。

### 第 4 步：确认新内核在跑

```bash
uname -r
```

期望看到类似 `7.2.8-bbrv3` 的输出（带 `-bbrv3` 后缀）。

### 第 5 步：应用调优

不确定选哪个就先用这个：

```bash
sudo bash /tmp/bbr.sh --tune=ai-gateway
```

它会同时设置拥塞控制、队列算法、缓冲区大小、内存水位，并按你的物理内存自动钳位上限。

### 第 6 步：确认生效

```bash
sudo bash /tmp/bbr.sh --status
```

期望：

```
TCP 拥塞控制   : bbr (v3)
队列管理算法   : fq
UDP 套接字缓冲 : 16 MB (AI/Hy2 专属大水管)
物理内存状态   : 712 MB (已开启 40% 防 OOM 保护)
持久化优化配置 : 已加载 (/etc/sysctl.d/99-bbr-v3-pro.conf)
```

看到 `bbr (v3)` 就说明 BBRv3 已经正确加载并生效。

### 第 7 步：验证重启后不会丢

```bash
sudo reboot
```

重连后再跑一次 `sudo bash /tmp/bbr.sh --status`，如果上面的输出保持不变，说明持久化配置已经在开机时自动加载了。

**至此完成。** 日常维护只需要偶尔跑一下 `--status` 看看状态。

---

## 功能详解

### 内核安装与卸载

| 命令 | 作用 |
|---|---|
| `--install-kernel` | 安装/更新最新 BBRv3 标准内核 |
| `--install-kernel=max` | 安装 Max 激进吞吐版（仅限自有链路测速实验）|
| `--uninstall-kernel` | 卸载自建内核，回滚到官方内核 |

**Max 版说明**：提高了 Startup、ProbeBW 和 cwnd 策略的进攻性，但保留 loss/ECN/inflight 反馈闭环。**只适合自有链路的极限测速，不建议生产环境使用。**

### 网络调优

| 命令 | 适用场景 | 特点 |
|---|---|---|
| `--apply-bbr` | 只想启用 BBR | 只改算法和队列，不动缓冲区，风险最低 |
| `--tune=ai-gateway` | 大多数 VPS 的默认选择 | TCP+UDP 全栈调优，按内存自动钳位 |
| `--tune=smart` | 知道自己的带宽和延迟 | 按 BDP 公式精算缓冲区，需要手输带宽和 RTT |
| `--tune=apac` | 香港/日本/新加坡等亚太直连 | 较小的缓冲区，低延迟优先 |

**可以叠加使用**：算法和调优参数分开存储，先跑 `--tune=ai-gateway` 再跑 `--apply-bbr` 不会互相清除。

**但调优预设之间是「替代」而非「叠加」**：

```
>>> qdisc 段（算法 + 队列）  →  只替换自己，不动 tune 段
>>> tune 段（缓冲区等调优）  →  整体替换，新的预设完全覆盖旧的
```

也就是说，`--tune=ai-gateway` 之后跑 `--tune=apac`，配置文件里**只会剩 apac 的参数**（包括 `tcp_mem` 这类只由 `ai-gateway` 写入的项也会消失）。

这是刻意设计——每个调优预设是一套完整方案，混着用会产生互相矛盾的参数。**想要哪套就最后跑哪套。**

### 队列算法与调优预设的关系

`>>> tune` 段**只写缓冲区类参数，不写队列算法**（`default_qdisc` 只属于 `>>> qdisc` 段）。所以：

- 切队列（菜单 3 / 4）与跑调优预设（菜单 5 / 6 / 7）**互不干扰，顺序无关**
- 但你运行的**每个调优预设内部都会先执行一次 `应用 BBR + FQ`**，这是为了保证 BBR 处于启用状态
- 因此：**如果你想要 CAKE，在跑完调优之后再切一次队列**

推荐顺序：

```
1. 先跑调优预设（菜单 5 / 6 / 7）—— 顺便把 BBR + FQ 打开
2. 再切队列（菜单 4 = BRR + CAKE）—— 这一步是最终生效的队列
```

反过来做（先 CAKE 再跑调优）也不会出错，只是队列会被调优预设里的 FQ 覆盖，需要再切一次。

> 不确定选哪个时，用这个对照：

| 需求 | 选 |
|---|---|
| 不确定，想要综合最优 | `--tune=ai-gateway` |
| 亚太低延迟线路（港/日/新） | `--tune=apac` |
| 知道确切带宽和 RTT | `--tune=smart` |
| 晚高峰延迟抖动明显 | 跑完调优后再切 CAKE |

### 其它

| 命令 | 作用 |
|---|---|
| `--status` | 查看内核、算法、队列、内存、安全缓解状态 |
| `--version` | 查看脚本版本 |
| `--update [--force]` | 把快捷命令 `bbr` 更新到最新版（`--force` 强制覆盖）|
| `--check-ports` | 检查 80/443/8443 端口占用，排查服务冲突 |
| `--clean` | 清空所有网络调优配置 |
| `--uninstall-all` | 彻底卸载工具本身 |
| `--help` | 查看全部参数 |

> `--version` 与 `--help` 不要求 root，普通用户也能执行。
>
> `--status` 与菜单顶部都会显示**脚本版本**，便于判断本地副本是否为最新。

### 调优参数明细

`--tune=ai-gateway` 写入以下参数（已按物理内存钳位）：

```ini
# 算法与队列
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# UDP / QUIC 缓冲区（Hysteria 2、Caddy HTTP/3）
net.core.rmem_max = <按内存计算>
net.core.wmem_max = <按内存计算>
net.core.netdev_max_backlog = <按内存分档：4096 或 10000>

# TCP 缓冲区与低延迟（VLESS、大模型 API 流式传输）
net.ipv4.tcp_rmem = 4096 87380 <按内存计算>
net.ipv4.tcp_wmem = 4096 65536 <按内存计算>
net.ipv4.tcp_mem = <按内存 10/25/40% 计算>
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
```

**内存自适应规则**：

| 物理内存 | 单 Socket 缓冲区上限 | 网卡接收队列 |
|---|---|---|
| < 600 MB | 8 MB | 4096 |
| 600 MB ~ 1.5 GB | 16 MB | 4096 |
| > 1.5 GB | 32 MB | 10000 |

三项额外保护：

- 缓冲区上限**再受物理内存 15% 硬钳位**（取两者较小值）
- 物理内存 < 256 MB 时**跳过 `tcp_mem`**（按比例算出的水位会低于内核默认值，反而收紧吞吐）
- `net.core.somaxconn` **只升不降**（当前值已 ≥ 4096 则完全不动，且不写入配置文件）

### 安全缓解

启动时自动写入 `/etc/modprobe.d/99-bbr-v3-pro-security.conf`：

```
blacklist esp4 / install esp4 /bin/false
blacklist esp6 / install esp6 /bin/false
blacklist rxrpc / install rxrpc /bin/false
blacklist algif_aead / install algif_aead /bin/false
```

前三项收敛 Dirty Frag 相关风险面（本项目的内核配置已在编译侧关闭这些模块，属于纵深防御）。`algif_aead` 对应 CVE-2026-31431，**仅在内核仍开启 AEAD 用户态接口时才写入**；一旦内核配置侧关闭该接口，脚本会自动移除这条规则。

`--status` 会回显当前缓解状态。

---

## 使用场景

### 场景一：512M / 768M 小内存 VPS 跑代理

**典型配置**：1 核 512M，跑 Xray/VLESS 或 Hysteria 2，晚高峰偶尔 OOM。

```bash
sudo bash /tmp/bbr.sh --install-kernel
sudo reboot
sudo bash /tmp/bbr.sh --tune=ai-gateway
```

**为什么用 `ai-gateway`**：它会把缓冲区上限钳制在物理内存 15% 以内，并把全局 `tcp_mem` 限制在 40% 水位内。这比手工写死 1GB 缓冲区安全得多——后者在小内存机器上会直接把系统打崩。

### 场景二：大带宽机器跑 AI API 网关

**典型配置**：4 核 8G，反代 OpenAI/Claude API，需要长连接流式传输。

```bash
sudo bash /tmp/bbr.sh --tune=ai-gateway
```

**关注点**：

- `tcp_slow_start_after_idle=0` —— 连接空闲后不重置拥塞窗口，避免每个请求都要重新加速
- `tcp_notsent_lowat=16384` —— 减少数据在内核缓冲里等待，降低首字节延迟
- `tcp_mtu_probing=1` —— 自动探测 MTU，避免跨线路的分片丢包

### 场景三：亚太短链路（港/日/新）

**典型配置**：香港 VPS，国内直连，RTT 30~80ms。

```bash
sudo bash /tmp/bbr.sh --tune=apac
```

**为什么不用 `ai-gateway`**：亚太线路延迟低，需要的缓冲区小得多。给太小的时延配大缓冲区，多出来的数据只会在队列里排队，反而增加延迟。

### 场景四：已知带宽和延迟，想要精确调优

**典型配置**：美西 VPS，500Mbps 带宽，国内访问 RTT 约 180ms。

```bash
sudo bash /tmp/bbr.sh --tune=smart
# 提示输入带宽时填 500
# 提示选择延迟档位时选「自定义输入」，填 180
```

脚本按 BDP 公式计算：`带宽(Mbps) × 125000 × RTT(ms) / 1000 × 3`，得到缓冲区大小，再受内存上限钳位。

**RTT 怎么测**：用你的客户端（如 v2rayN）测出的真实延迟，**不要用 Speedtest 的 Ping**——那是到测速节点的延迟，不是你的业务线路。

### 场景五：只想启用 BBR，不想动系统参数

**典型配置**：生产机，不敢改太多东西。

```bash
sudo bash /tmp/bbr.sh --apply-bbr
```

只设置 `default_qdisc=fq` 和 `tcp_congestion_control=bbr` 两个参数，不动任何缓冲区。**风险最低，也最容易回滚。**

### 场景六：晚高峰网络拥堵，需要抗延迟抖动

```bash
sudo bash /tmp/bbr.sh --apply-bbr   # 先启用 BBR
# 然后进菜单选第 4 项「启用 BBR + CAKE」
bbr
```

**CAKE 的优势**：自带流隔离和 ACK 过滤，在同机有多个服务抢带宽时，能保护交互流量的延迟。比基础的 fq 更抗队头阻塞。

### 场景七：排查端口冲突

```bash
sudo bash /tmp/bbr.sh --check-ports
```

检查 80 / 443（TCP+UDP）/ 8443 的占用情况，并支持自定义端口查询。适合在部署 Caddy、Nginx、Hysteria 2 之前确认端口没被占。

### 场景八：想完全还原，或彻底卸载

```bash
# 只还原网络配置（保留内核和工具）
sudo bash /tmp/bbr.sh --clean

# 彻底卸载（清配置 + 删快捷命令 + 删临时文件）
sudo bash /tmp/bbr.sh --uninstall-all
```

**注意**：`--clean` 只删除持久化配置文件，**已经写入内核的运行态参数会保持到重启**。脚本会列出这些参数提醒你。

---

## 如何确认调优生效了

不要只看脚本说"成功"，自己验证两步：

**第一步：看运行态**

```bash
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
sysctl net.core.rmem_max net.ipv4.tcp_rmem
```

**第二步：看持久化配置**

```bash
cat /etc/sysctl.d/99-bbr-v3-pro.conf
```

正常应该长这样（两个段，各一对标记）：

```
# >>> qdisc
# bbr-v3-pro: congestion control & qdisc
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# <<< qdisc
# >>> tune
# bbr-v3-pro: AI Gateway & High-Throughput Cross-Pacific Tuning
net.core.rmem_max = 16777216
...
# <<< tune
```

**两个段的作用**：算法配置和调优参数分开存放，切换算法时不会清掉调优参数。如果你看到文件里有**重复的段**或**某个段消失了**，那说明有问题，请提 issue。

**确认真实生效（而不是只写进了文件）**：重启后再跑一次检查。持久化配置只在开机时加载，重启后参数还在，才算真的生效。

**检查网卡队列是否也切了**（`default_qdisc` 只影响新建队列）：

```bash
tc qdisc show dev $(ip route show default | awk '{print $5; exit}')
```

---

## 卸载与还原

### 完整还原顺序

```bash
# 1. 还原网络配置
sudo bash /tmp/bbr.sh --clean

# 2. 卸载 BBRv3 内核，回滚到官方内核
sudo bash /tmp/bbr.sh --uninstall-kernel

# 3. 重启
sudo reboot
```

### 卸载内核的保护机制

`--uninstall-kernel` 在删除前会先检查系统里**是否还保留官方内核**。如果没有，它会**拒绝卸载**并提示你先装官方内核：

```
[ERROR] 【高危拦截】系统未检测到任何官方备用内核！
[WARN] 若此时卸载 BBRv3 内核，系统重启后将因无可用内核直接失联变砖！
```

这是防止变砖的关键保护，**请勿绕过**。

### 建议

卸载内核前，先确认：

1. VPS 控制台 / 救援模式可用
2. 系统里有官方内核可引导：`dpkg -l | grep linux-image`
3. 手边有 VPS 服务商的重装入口

---

## 自己编译内核

不想用官方 Release，想自己编译？项目内置了 GitHub Actions 流水线。

### 步骤

1. Fork 本仓库到你的账号
2. 进入 `Settings → Actions → General`，把 Workflow permissions 设为 **Read and write**
3. 进入 `Actions → 构建带有BBRv3的内核 → Run workflow`
4. 等待约 1~2 小时
5. 编译产物会自动发布到你仓库的 Releases

### 流水线参数

| 参数 | 说明 |
|---|---|
| `force_rebuild` | 勾选后忽略"已存在"检查，强制重新编译。用于打包层变更（如版本号规则、校验文件）需要在同一内核版本重新出包时 |
| `kernel_version` | 指定要编译的内核版本（如 `7.2.8`）。留空则使用 kernel.org 当前最新 stable |

> ⚠️ 同一 tag 强制重建会与旧 Release 的产物混在一起（deb 版本号变化导致文件名不同，旧文件不会被覆盖）。**建议先删除对应 Release 再强制重建。**

### 使用自己的内核

```bash
BBR_REPO="你的用户名/bbr-v3-pro" sudo bash /tmp/bbr.sh --install-kernel
```

如果私有仓库还没发布内核包，脚本**只提示并退出，不会自动改用第三方源**（你的意图显然是只用自有内核）。确实需要回退到上游时才显式声明：

```bash
BBR_ALLOW_UPSTREAM=1 BBR_REPO="你的用户名/bbr-v3-pro" sudo bash /tmp/bbr.sh --install-kernel
```

### 流水线做了什么

1. 从 kernel.org 读取最新 stable 版本
2. 从 `gregkh/linux` 拉取对应 stable 分支
3. 应用仓库内固定的 BBRv3 补丁（`patches/`）
4. 应用内核配置策略（BBR 内置为默认、fq 为默认队列、关闭 debug info 与 IPsec 风险面）
5. **逐项校验配置**，不符则中断（不会产出配置错误的包）
6. 编译并打包成 `.deb`，生成 `SHA256SUMS`
7. 发布到 Releases

**BBRv3 补丁是固定的**，自动更新的是 Linux stable 内核版本。

---

## 常见问题

### 装完 `uname -r` 没变化？

三种可能：

1. **没重启** —— 内核必须重启才生效
2. **GRUB 默认项没变** —— 重启时在 GRUB 菜单里手动选带 `-bbrv3` 的项，进去后检查 `grub-set-default`
3. **包的版本号没变** —— 脚本会检测到并提示"内核映像未发生变化"。这种情况需要重新构建带唯一版本号的包

### 提示"该 Release 未提供 SHA256SUMS，本次安装无法做完整性校验"？

说明这个 Release 是旧流水线构建的，没有校验文件。**不影响安装**，但建议自行比对发布页给出的哈希值，或等下一个内核版本（新流水线会自动生成）。

### 报"内核拒绝写入 xxx"或"xxx 未被完全采纳"？

说明这个参数在当前内核上不被支持，或者值超出了内核硬上限。脚本会列出所有失败的参数。常见原因：

- 内核没有编译该参数
- 值超过硬件上限
- 小内存机器的水位算出来低于内核默认值（比如 `tcp_mem`）

**这不影响其它参数生效**，可以按提示单独排查。

### `--clean` 之后参数还在？

正常。`--clean` 只删除持久化配置文件，**已经写进内核的运行态值不会自动回退**，重启后才恢复系统默认。脚本会列出这些参数。

### 快捷命令 `bbr` 会不会自动更新？

**不会。** 它是首次运行时缓存的一份副本——这样设计是为了**离线可用、启动快**，代价是需要手动更新：

```bash
bbr --update
```

一条命令完成：下载 → 校验内容 → 比较版本 → 覆盖 → 恢复权限。

如果提示"已是最新版本"但你认为上游确实更新了，通常是 raw CDN 缓存未刷新，等几分钟重试即可。确认要强制覆盖：

```bash
bbr --update --force
```

### 怎么知道我的 `bbr` 是不是最新版？

```bash
bbr --version
```

对比 GitHub 上 `install.sh` 里的 `BBR_SCRIPT_VERSION`（或仓库的版本标签）即可。

`bbr --status` 和菜单顶部也会显示脚本版本，一眼可见。

### 每次重新执行那条 `bash <(curl ...)` 命令，要重新给执行权限吗？

**不需要。** `chmod` 改的是文件属性，设一次就永久保留。

另外，用 `bash /usr/local/bin/bbr` 这种方式调用只需要**读权限**，连执行权限都不需要。

### 支持 Alpine / CentOS / 其它发行版吗？

**不支持。** 内核产物是 `.deb`，安装流程依赖 Debian/Ubuntu 的包管理和内核安装链路。脚本启动时会检查 `apt-get` 是否存在。

### 会不会影响同机其它服务？

脚本对影响面大的参数做了保守处理：

- `net.core.somaxconn` 只升不降（已 ≥4096 则完全不动）
- `netdev_max_backlog` 按内存分档，小机器给 4096 而非 10000
- 所有参数写入后回读校验，失败会明确告警

但仍建议在业务低峰期操作，并提前做好快照。

---

## 已知限制

诚实说明，避免踩坑：

1. **主要验证环境有限**：核心流程在 Debian 12 / x86_64 / 712MB 的 VPS 上完整验证过。ARM 架构、Ubuntu 系统、大内存（>2GB）、极小内存（<256MB）的实际表现尚未充分验证。
2. **`SHA256SUMS` 校验链路未在真实产物上验证**：功能已实现，但现有 Release 是旧流水线产物，不含校验文件。触发一次重新构建后即可验证。
3. **不支持回退到旧版本内核**：只能安装最新版。如需回退，请手工下载对应 Release 的 `.deb`。
4. **不支持 Alpine / 非 Debian 系**。
5. **少数入口未在真机执行**：菜单 6 / 7 / 12 与 `--uninstall-all` 仅做过本地逻辑测试。其中 `--uninstall-all` 会删除快捷命令，建议最后再试。

### 已实机验证的功能

以下均在真实 VPS 上执行并确认结果：

| 功能 | 验证内容 |
|---|---|
| 菜单 1 / `--status` | 状态体检、脚本版本显示 |
| 菜单 2 / `--install-kernel` | 内核下载、无 SHA256SUMS 时如实告警、安装成功路径、同版本前置检查 |
| 菜单 3 / `--apply-bbr` | 算法与队列切换、持久化 |
| 菜单 4 | 切换 CAKE，网卡实际队列回读 |
| 菜单 5 / `--tune=ai-gateway` | 全栈调优、内存分档、跳过项不落盘 |
| 菜单 8 / `--check-ports` | 端口占用探测 |
| 菜单 9 / `--clean` | 配置清空 + 运行态参数提示 |
| 菜单 10 / `--uninstall-kernel` | **防变砖断言触发**（正确识别官方兜底内核后才允许卸载）|
| `--tune=smart` / `--tune=apac` | BDP 计算、亚太预设 |
| 重启持久化 | 重启后参数与配置自动恢复 |
| 段标记机制 | 8 轮混合操作后配置无重复、无残留 |
| 快捷命令 | 非 ELF、`--version` 可用 |

---

## 目录结构

```text
bbr-v3-pro/
├── .github/workflows/
│   ├── build.yml                # 云端编译 BBRv3 内核流水线
│   └── lint.yml                 # 脚本语法与静态检查
├── patches/                     # BBRv3 内核补丁（7.0 / 7.1 / 7.2）
├── scripts/
│   ├── apply-bbrv3-port.sh      # 打补丁（含失败回退与质量断言）
│   ├── apply-bbrv3-max-profile.sh  # Max 版激进配置
│   ├── prepare-kernel-config.sh # 内核配置策略与逐项校验
│   └── build-bbrv3-max-kernel.sh   # 本地编译辅助脚本
├── arm64.config / x86-64.config # 内核编译配置模板
├── cve_2026_31431_detector.py   # CVE 检测脚本（仅检测，不利用）
├── install.sh                   # 主脚本
└── README.md
```

---

## 开源协议

[MIT](LICENSE)
