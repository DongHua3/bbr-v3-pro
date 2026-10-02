# bbr-v3-pro

生产级 Linux 双栈网络调优、拥塞控制与 BBR 管理系统。

纯净无第三方广告、无 Emoji、针对 **TCP (VLESS / API 网关)** 与 **UDP (Hysteria 2 / QUIC / Caddy HTTP/3)** 实施双栈深度协同优化，并集成针对 512M / 768M / 1G 小内存 VPS 的物理内存防 OOM 动态保护算法。

---

## 核心特性

* **完全纯净自包含**：移除所有第三方个人外链、TG 推广、水印与广告，遵循工业级 Unix 日志标准（`[INFO]`、`[OK]`、`[WARN]`、`[ERROR]`）。
* **TCP + UDP 复合全栈调优**：
  * **TCP 侧**：禁用空闲慢启动（`tcp_slow_start_after_idle=0`），开启 MTU 黑洞探测，优化长链路大 Token 传输，为 `cliproxyapi` 大模型 API 网关与 VLESS 提供低延迟瞬时响应。
  * **UDP 侧**：按物理内存动态计算并拓宽套接字缓冲区（`rmem_max / wmem_max` 到 16MB），拉大网卡驱动接收队列至 10000，彻底消除 Hysteria 2 端口跳跃与 Caddy HTTP/3 的高并发丢包。
* **物理内存动态钳位（OOM 保护）**：
  * 将全局 `tcp_mem` 严格限制在物理内存的 40% 水位内；
  * 单套接字最大缓冲区限制在物理内存的 15% 以内，彻底告别硬编码 1GB 内存缓冲区引发的系统崩溃与杀进程。
* **原子化防砖内核安装**：
  * 颠倒旧版“先删旧内核再装新内核”的高危顺序；
  * 实行“先部署新包 ➔ 校验引导记录 ➔ 确认系统保留官方救援内核 ➔ 成功后再引导重启”，杜绝变砖失联。
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

# 一键启用原生 BBR + FQ (官方内核 / 零风险)
./install.sh --apply-bbr

# 一键应用智能全栈调优 (AI网关+跨洋大带宽+TCP+UDP复合)
./install.sh --tune=ai-gateway

# 一键应用亚太短链路低延迟调优
./install.sh --tune=apac

# 探测系统关键端口冲突状态 (80 / 443 / 8443)
./install.sh --check-ports

# 一键清空所有自定义网络优化，彻底恢复出厂默认值
./install.sh --clean
```

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
4. 编译完成后，安装包将自动推送到您自己仓库的 Releases 中；
5. 编译完成后，安装包将自动推送到您自己仓库的 Releases 中，`install.sh` 脚本已预设直接对接 `DongHua3/bbr-v3-pro`，即可实现 100% 个人私有闭环安装！

---

## 开源协议

本项目采用 [MIT](LICENSE) 开源协议。
