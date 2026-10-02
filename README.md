# bbr-v3-pro

生产级 Linux 双栈网络调优、拥塞控制与 BBR 管理系统。

纯净无第三方广告、无 Emoji、针对 **TCP (VLESS / API 网关)** 与 **UDP (Hysteria 2 / QUIC / Caddy HTTP/3)** 实施双栈深度协同优化，并集成针对 512M / 768M / 1G 小内存 VPS 的物理内存防 OOM 动态保护算法。

---

## 核心特性

* **完全纯净自包含**：移除所有第三方个人外链、TG 推广、水印与广告，遵循工业级 Unix 日志标准（`[INFO]`、`[OK]`、`[WARN]`、`[ERROR]`）。
* **TCP + UDP 复合全栈调优**：
  * **TCP 侧**：禁用空闲慢启动（`tcp_slow_start_after_idle=0`），开启 MTU 黑洞探测，优化长链路大 Token 传输，为 `cliproxyapi` 大模型 API 网关与 VLESS 提供低延迟瞬时响应。
  * **UDP 侧**：按物理内存动态计算并拓宽套接字缓冲区，网卡驱动接收队列按内存分档（<1GB 用 4096，≥1GB 用 10000），降低 Hysteria 2 端口跳跃与 Caddy HTTP/3 的高并发丢包。
* **物理内存动态钳位（OOM 保护）**：
  * 将全局 `tcp_mem` 限制在物理内存的 40% 水位内；**内存小于 256MB 时自动跳过该项**，因为按比例算出的水位会低于内核默认值，反而收紧吞吐；
  * 单套接字最大缓冲区限制在物理内存的 15% 以内，彻底告别硬编码 1GB 内存缓冲区引发的系统崩溃与杀进程；
  * `net.core.somaxconn` 只升不降（当前值已 ≥4096 则不动），避免影响同机其它服务的 accept 队列行为。
* **安全缓解**：写入 `/etc/modprobe.d/99-bbr-v3-pro-security.conf`，对 `esp4` / `esp6` / `rxrpc` 做黑名单收敛；内核若仍开启 AEAD 用户态接口（`CONFIG_CRYPTO_USER_API_AEAD`），额外写入 `algif_aead` 黑名单，并在内核配置侧关闭该接口后自动移除。菜单第 1 项会回显安全缓解状态。
* **内核安装防砖**：
  * 不预先删除旧内核包，新包安装失败时原有内核完整保留；
  * 安装后回读 `/boot/vmlinuz-*` 与安装前比对，一致的（例如 deb 版本号与已装版本相同被 dpkg 判为重复安装）会明确报错而非谎报成功；
  * 卸载前强制断言系统仍保留官方兜底内核，否则拒绝卸载。
* **双模接口（TUI + CLI）**：支持直观交互菜单与脚本化非交互 CLI 参数调用。

---

## 快速使用

### 1. 一键交互式运行
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DongHua3/bbr-v3-pro/main/install.sh)
```

### 2. 自动化 CLI 指令模式（适合脚本与无人值守）

```bash
# 查看当前网络拥塞算法、队列与内存状态
./install.sh --status

# 安装或更新最新 BBRv3 内核 (自建 Release)
./install.sh --install-kernel

# 安装最新 BBRv3 Max 激进吞吐内核（仅适合自有链路测速实验）
./install.sh --install-kernel=max

# 一键启用原生 BBR + FQ (官方内核 / 零风险)
./install.sh --apply-bbr

# 一键应用 AI 网关与跨洋全栈调优预设 (TCP+UDP复合)
./install.sh --tune=ai-gateway

# 一键应用智能 BDP 动态带宽调优
./install.sh --tune=smart

# 一键应用亚太短链路低延迟调优
./install.sh --tune=apac

# 探测系统关键端口冲突状态 (80 / 443 / 8443)
./install.sh --check-ports

# 一键清空所有自定义网络优化，彻底恢复出厂默认值
./install.sh --clean

# 安全卸载 BBRv3 内核并回滚引导
./install.sh --uninstall-kernel

# 彻底卸载本工具及所有网络配置 (清理快捷命令及残留)
./install.sh --uninstall-all
```

### 3. 私有源与上游回退

脚本默认从官方中央源 `DongHua3/bbr-v3-pro` 获取内核。若你 fork 后希望**只使用自己编译的内核**：

```bash
BBR_REPO="你的用户名/bbr-v3-pro" ./install.sh --install-kernel
```

此时如果私有仓库还没有发布内核包，脚本**只会提示并退出，不会自动改用第三方源**。确实需要回退到上游中央源时，必须显式声明：

```bash
BBR_ALLOW_UPSTREAM=1 BBR_REPO="你的用户名/bbr-v3-pro" ./install.sh --install-kernel
```

> 内核是最高权限代码。若 Release 中附带 `SHA256SUMS`，脚本会逐包校验并在不匹配时中止；未附带时只提示"无法校验"，不会伪装成已校验通过。CI 流水线会自动生成该文件。

---

## 目录结构

```text
bbr-v3-pro/
├── .github/workflows/
│   └── build.yml               # GitHub Actions 云端自动编译打包 BBRv3 主线内核流水线
├── patches/                     # Google BBRv3 官方主线内核补丁 (7.0 / 7.1 / 7.2)
├── scripts/                     # 内核配置生成与构建辅助脚本
├── arm64.config & x86-64.config # 内核编译标准配置模板
├── cve_2026_31431_detector.py   # 安全漏洞与模块暴露检测脚本
├── install.sh                   # 核心管理与双栈调优主脚本
└── README.md                    # 项目文档
```

---

## 云端自主编译 BBRv3 内核 (可选)

本项目内置了完整的 GitHub Actions 自动化编译工作流（`.github/workflows/build.yml`）：

1. Fork 或推送到您自己的 GitHub 仓库；
2. 在仓库的 `Settings -> Actions -> General` 中，确保 Workflow 拥有 `Read and write permissions`；
3. 进入 `Actions` 页面，手动触发 `构建带有BBRv3的内核`，GitHub 云端服务器将自动拉取最新主线 Linux 内核并打上 BBRv3 补丁完成打包；
4. 编译完成后，安装包将自动推送到您自己仓库的 Releases 中（同时附带 `SHA256SUMS` 供安装脚本校验）；
5. 把 `install.sh` 的 `BBR_REPO` 指向你的仓库即可使用自有内核：

```bash
BBR_REPO="你的用户名/bbr-v3-pro" bash install.sh --install-kernel
```

> 私有仓库尚未发布内核包时，脚本默认**只提示不切换**（见上文"私有源与上游回退"）。需要自动回退到上游时设置 `BBR_ALLOW_UPSTREAM=1`。
>
> 注意：CI 使用 `KDEB_PKGVERSION` 生成唯一 deb 版本号。若你自行构建时省掉该参数，同一内核版本重复构建会产生 dpkg 判定为"同版本"的包，`dpkg -i` 会跳过安装——安装脚本会检测到 `/boot` 未变化并明确报错。

---

## 开源协议

本项目采用 [MIT](LICENSE) 开源协议。
