#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
CVE-2026-31431 风险面检测脚本（仅检测，不利用）

检测项：
1) CVE-2026-31431 风险面（AEAD userspace 接口）
2) Dirty Frag 风险面（ESP/RXRPC 相关模块与配置）
"""

import gzip
import os
import socket
import subprocess
from typing import Optional, Tuple


def get_kernel_release() -> str:
    return subprocess.check_output(["uname", "-r"], text=True).strip()


def read_kernel_config(kernel_release: str) -> Optional[str]:
    boot_cfg = f"/boot/config-{kernel_release}"
    if os.path.exists(boot_cfg):
        with open(boot_cfg, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()

    proc_cfg = "/proc/config.gz"
    if os.path.exists(proc_cfg):
        with gzip.open(proc_cfg, "rt", encoding="utf-8", errors="ignore") as f:
            return f.read()

    return None


def parse_tristate_symbol(config_text: Optional[str], symbol: str) -> str:
    if not config_text:
        return "未知（未找到内核配置）"

    key = f"CONFIG_{symbol}="
    disabled = f"# CONFIG_{symbol} is not set"
    for line in config_text.splitlines():
        if line.startswith(key):
            return line.split("=", 1)[1].strip()
        if line.strip() == disabled:
            return "n"
    return "未知（配置项不存在）"


def parse_aead_config(config_text: Optional[str]) -> str:
    return parse_tristate_symbol(config_text, "CRYPTO_USER_API_AEAD")


def is_module_loaded(module_name: str) -> bool:
    norm_name = module_name.replace("-", "_")
    try:
        with open("/proc/modules", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith(norm_name + " ") or line.startswith(module_name + " "):
                    return True
    except OSError:
        return False
    return False


def check_af_alg_aead_bind(
    safe_check: bool = True,
    aead_cfg: Optional[str] = None,
    mod_loaded: Optional[bool] = None,
    aead_rules_ok: bool = False,
) -> Tuple[bool, str]:
    """探测 AF_ALG AEAD bind 可用性。

    在执行 bind 探测前执行防御性检查，防止探测本身触发内核
    request_module 主动加载 algif_aead 漏洞模块。
    """
    if safe_check:
        if mod_loaded is None:
            mod_loaded = is_module_loaded("algif_aead")

        # 1. 内核配置已显式关闭，跳过探测
        if aead_cfg == "n":
            return False, "跳过（内核配置已显式禁用 CONFIG_CRYPTO_USER_API_AEAD）"

        # 2. 模块未加载且非 built-in：bind 会触发 kernel request_module("algif-aead")
        # 防御性跳过，防止探测本身成为漏洞模块加载触发源
        if not mod_loaded and aead_cfg != "y":
            if aead_rules_ok:
                return False, "防御性跳过（模块未加载且已受黑名单拦截，避免触发 request_module）"
            return False, "防御性跳过（模块未加载，防止探测本身触发内核 request_module 主动加载）"

    af_alg = getattr(socket, "AF_ALG", 38)
    sock_type = getattr(socket, "SOCK_SEQPACKET", 5)

    try:
        sock = socket.socket(af_alg, sock_type, 0)
    except OSError as e:
        return False, f"创建 socket 失败: {e}"

    try:
        sock.bind(("aead", "authencesn(hmac(sha256),cbc(aes))"))
        return True, "bind 成功"
    except OSError as e:
        return False, f"bind 失败: {e}"
    finally:
        try:
            sock.close()
        except OSError:
            pass


def read_security_conf(path: str) -> str:
    if not os.path.exists(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except OSError:
        return ""


def has_rule(text: str, rule: str) -> bool:
    rule_tokens = rule.split()
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if line.split() == rule_tokens:
            return True
    return False


def main() -> None:
    kernel = get_kernel_release()
    cfg = read_kernel_config(kernel)
    aead_cfg = parse_aead_config(cfg)
    mod_loaded = is_module_loaded("algif_aead")

    security_conf_path = "/etc/modprobe.d/99-bbr-v3-pro-security.conf"
    security_conf = read_security_conf(security_conf_path)

    aead_rules_ok = all(
        has_rule(security_conf, rule)
        for rule in (
            "blacklist algif_aead",
            "install algif_aead /bin/false",
        )
    )

    dirtyfrag_rules_ok = all(
        has_rule(security_conf, rule)
        for rule in (
            "blacklist esp4",
            "install esp4 /bin/false",
            "blacklist esp6",
            "install esp6 /bin/false",
            "blacklist rxrpc",
            "install rxrpc /bin/false",
        )
    )

    bind_ok, bind_msg = check_af_alg_aead_bind(
        safe_check=True,
        aead_cfg=aead_cfg,
        mod_loaded=mod_loaded,
        aead_rules_ok=aead_rules_ok,
    )

    xfrm_esp = parse_tristate_symbol(cfg, "XFRM_ESP")
    inet_esp = parse_tristate_symbol(cfg, "INET_ESP")
    inet6_esp = parse_tristate_symbol(cfg, "INET6_ESP")
    af_rxrpc = parse_tristate_symbol(cfg, "AF_RXRPC")

    esp4_loaded = is_module_loaded("esp4")
    esp6_loaded = is_module_loaded("esp6")
    rxrpc_loaded = is_module_loaded("rxrpc")

    print(f"[*] 当前内核: {kernel}")
    print("")
    print("[CVE-2026-31431 检测]")
    print(f"[*] CONFIG_CRYPTO_USER_API_AEAD: {aead_cfg}")
    print(f"[*] algif_aead 已加载: {mod_loaded}")
    print(f"[*] algif_aead 黑名单规则完整: {aead_rules_ok} ({security_conf_path})")
    print(f"[*] AF_ALG AEAD bind 可用: {bind_ok} ({bind_msg})")

    print("")
    print("[Dirty Frag 检测]")
    print(f"[*] CONFIG_XFRM_ESP: {xfrm_esp}")
    print(f"[*] CONFIG_INET_ESP: {inet_esp}")
    print(f"[*] CONFIG_INET6_ESP: {inet6_esp}")
    print(f"[*] CONFIG_AF_RXRPC: {af_rxrpc}")
    print(f"[*] esp4 已加载: {esp4_loaded}")
    print(f"[*] esp6 已加载: {esp6_loaded}")
    print(f"[*] rxrpc 已加载: {rxrpc_loaded}")
    print(f"[*] Dirty Frag 黑名单规则完整: {dirtyfrag_rules_ok} ({security_conf_path})")

    print("")
    print("[检测结论]")

    cfg_present = cfg is not None

    # CVE-2026-31431 风险评估:
    # 高危：用户态 bind 成功、模块已在内存中运行、built-in 编入内核，或模块化编译且无黑名单防护
    cve_high_risk = (
        bind_ok
        or mod_loaded
        or (aead_cfg == "y")
        or (aead_cfg == "m" and not aead_rules_ok)
    )
    # 收敛：未加载且未暴露 bind，且（配置侧已显式关闭，或模块化编译但在黑名单阻断下）
    cve_reduced = (
        not mod_loaded
        and not bind_ok
        and aead_cfg != "y"
        and (
            aead_cfg == "n"
            or (cfg_present and aead_cfg == "m" and aead_rules_ok)
        )
    )

    # Dirty Frag 风险评估:
    # 运行时暴露：任一易受攻击模块已在内核内存中运行
    dirtyfrag_runtime_exposed = esp4_loaded or esp6_loaded or rxrpc_loaded
    dirtyfrag_cfg_exposed = any(v in {"y", "m"} for v in (xfrm_esp, inet_esp, inet6_esp, af_rxrpc))
    dirtyfrag_has_builtin = any(v == "y" for v in (xfrm_esp, inet_esp, inet6_esp, af_rxrpc))
    dirtyfrag_cfg_all_disabled = cfg_present and all(
        v == "n" for v in (xfrm_esp, inet_esp, inet6_esp, af_rxrpc)
    )

    # 高危：模块在内存中运行，或有 built-in 编入，或配置开启但黑名单不完整
    dirtyfrag_high_risk = (
        dirtyfrag_runtime_exposed
        or dirtyfrag_has_builtin
        or (dirtyfrag_cfg_exposed and not dirtyfrag_rules_ok)
    )
    # 收敛：内存中未运行，且（配置显式全部关闭，或黑名单完整且无 built-in 编入）
    dirtyfrag_reduced = (
        not dirtyfrag_runtime_exposed
        and (
            dirtyfrag_cfg_all_disabled
            or (cfg_present and dirtyfrag_rules_ok and not dirtyfrag_has_builtin)
        )
    )

    if cve_high_risk:
        print("[!] 检测到高风险暴露面。")
        print("[!] 若内核未包含上游修复补丁，系统可能受 CVE-2026-31431 影响。")
        print("[!] 建议：升级到新构建内核，或禁用 CRYPTO_USER_API_AEAD；旧内核可临时屏蔽 algif_aead。")
    elif cve_reduced:
        print("[+] 风险面已收敛/已缓解。")
    else:
        print("[?] 结果不确定，请继续核对内核补丁级别。")

    if dirtyfrag_high_risk:
        print("[!] Dirty Frag 风险面暴露。")
        print("[!] 建议：禁用 XFRM_ESP/INET_ESP/INET6_ESP/AF_RXRPC，并屏蔽 esp4/esp6/rxrpc。")
    elif dirtyfrag_reduced:
        print("[+] Dirty Frag 风险面已收敛/已缓解。")
    else:
        print("[?] Dirty Frag 结果不确定，请继续核对内核补丁级别。")


if __name__ == "__main__":
    main()
