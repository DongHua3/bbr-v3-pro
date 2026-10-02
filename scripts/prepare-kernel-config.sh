#!/usr/bin/env bash
set -euxo pipefail

arch="${1:?usage: prepare-kernel-config.sh <x86_64|arm64>}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
workspace="${GITHUB_WORKSPACE:-$repo_root}"

run_olddefconfig() {
  if [ "$arch" = "arm64" ]; then
    timeout 300 make ARCH=arm64 olddefconfig < /dev/null
  else
    timeout 300 make olddefconfig < /dev/null
  fi
}

apply_policy_config() {
  scripts/config --disable SYSTEM_TRUSTED_KEYS
  scripts/config --disable SYSTEM_REVOCATION_KEYS

  scripts/config --enable TCP_CONG_BBR
  scripts/config --disable DEFAULT_CUBIC
  scripts/config --enable DEFAULT_BBR
  scripts/config --set-str DEFAULT_TCP_CONG bbr

  scripts/config --enable NET_SCH_DEFAULT
  scripts/config --enable NET_SCH_FQ
  scripts/config --module NET_SCH_FQ_CODEL
  scripts/config --module NET_SCH_PIE
  scripts/config --module NET_SCH_FQ_PIE
  scripts/config --module NET_SCH_CAKE
  scripts/config --disable DEFAULT_FQ_CODEL
  scripts/config --disable DEFAULT_PFIFO_FAST
  scripts/config --enable DEFAULT_FQ
  scripts/config --set-str DEFAULT_NET_SCH fq

  scripts/config --module NETFILTER_XTABLES
  scripts/config --enable NETFILTER_XTABLES_LEGACY
  scripts/config --module IP_NF_IPTABLES_LEGACY
  scripts/config --module IP_NF_FILTER
  scripts/config --module IP_NF_NAT
  scripts/config --module IP_NF_TARGET_MASQUERADE
  scripts/config --module IP_NF_MANGLE
  scripts/config --module IP_NF_RAW
  scripts/config --module IP6_NF_IPTABLES_LEGACY
  scripts/config --module IP6_NF_FILTER
  scripts/config --module IP6_NF_NAT
  scripts/config --module IP6_NF_MANGLE
  scripts/config --module IP6_NF_RAW

  scripts/config --disable DEBUG_INFO
  scripts/config --enable DEBUG_INFO_NONE
  scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
  scripts/config --disable DEBUG_INFO_DWARF4
  scripts/config --disable DEBUG_INFO_DWARF5
  scripts/config --disable DEBUG_INFO_REDUCED
  scripts/config --disable DEBUG_INFO_COMPRESSED
  scripts/config --disable DEBUG_INFO_SPLIT
  scripts/config --disable DEBUG_INFO_BTF
  scripts/config --disable DEBUG_INFO_BTF_MODULES
  scripts/config --disable MODULE_ALLOW_BTF_MISMATCH

  scripts/config --disable AFS_FS
  scripts/config --disable XFRM_ESP
  scripts/config --disable INET_ESP
  scripts/config --disable INET6_ESP
  scripts/config --disable AF_RXRPC
  scripts/config --disable RXKAD

  scripts/config --enable HYPERV
  if [ "$arch" = "x86_64" ]; then
    scripts/config --enable HYPERV_TIMER
  fi
  scripts/config --module HYPERV_UTILS
  scripts/config --module HYPERV_BALLOON
  scripts/config --module HYPERV_NET
  scripts/config --module HYPERV_STORAGE
  scripts/config --module HYPERV_KEYBOARD
  scripts/config --module HID_HYPERV_MOUSE
  scripts/config --module PCI_HYPERV
  scripts/config --module PCI_HYPERV_INTERFACE
  scripts/config --module DRM_HYPERV
  scripts/config --module HYPERV_VSOCKETS
}

require_config_line() {
  local line="$1"
  local message="$2"
  if ! grep -q "^${line}$" .config; then
    echo "ERROR: $message"
    exit 1
  fi
}

reject_enabled_config() {
  local symbol="$1"
  if grep -q "^${symbol}=" .config; then
    echo "ERROR: ${symbol} is enabled; refusing to continue."
    exit 1
  fi
}

validate_config() {
  reject_enabled_config CONFIG_XFRM_ESP
  reject_enabled_config CONFIG_INET_ESP
  reject_enabled_config CONFIG_INET6_ESP
  reject_enabled_config CONFIG_AF_RXRPC
  reject_enabled_config CONFIG_DEBUG_INFO

  require_config_line 'CONFIG_TCP_CONG_BBR=y' 'CONFIG_TCP_CONG_BBR is not built in.'
  require_config_line 'CONFIG_DEFAULT_BBR=y' 'CONFIG_DEFAULT_BBR is not enabled.'
  require_config_line 'CONFIG_DEFAULT_TCP_CONG="bbr"' 'CONFIG_DEFAULT_TCP_CONG is not bbr.'
  require_config_line 'CONFIG_NET_SCH_FQ=y' 'CONFIG_NET_SCH_FQ is not built in.'
  require_config_line 'CONFIG_NET_SCH_FQ_CODEL=m' 'CONFIG_NET_SCH_FQ_CODEL is not module-enabled.'
  require_config_line 'CONFIG_NET_SCH_PIE=m' 'CONFIG_NET_SCH_PIE is not module-enabled.'
  require_config_line 'CONFIG_NET_SCH_FQ_PIE=m' 'CONFIG_NET_SCH_FQ_PIE is not module-enabled.'
  require_config_line 'CONFIG_NET_SCH_CAKE=m' 'CONFIG_NET_SCH_CAKE is not module-enabled.'
  require_config_line 'CONFIG_NET_SCH_DEFAULT=y' 'CONFIG_NET_SCH_DEFAULT is not enabled.'
  require_config_line 'CONFIG_DEFAULT_FQ=y' 'CONFIG_DEFAULT_FQ is not enabled.'
  require_config_line 'CONFIG_DEFAULT_NET_SCH="fq"' 'CONFIG_DEFAULT_NET_SCH is not fq.'
  require_config_line 'CONFIG_NETFILTER_XTABLES_LEGACY=y' 'CONFIG_NETFILTER_XTABLES_LEGACY is not enabled.'
  require_config_line 'CONFIG_IP_NF_IPTABLES_LEGACY=m' 'CONFIG_IP_NF_IPTABLES_LEGACY is not module-enabled.'
  require_config_line 'CONFIG_IP_NF_NAT=m' 'CONFIG_IP_NF_NAT is not module-enabled.'
  require_config_line 'CONFIG_IP_NF_FILTER=m' 'CONFIG_IP_NF_FILTER is not module-enabled.'
  require_config_line 'CONFIG_IP_NF_TARGET_MASQUERADE=m' 'CONFIG_IP_NF_TARGET_MASQUERADE is not module-enabled.'
  require_config_line 'CONFIG_HYPERV=y' 'CONFIG_HYPERV is not enabled.'
  if [ "$arch" = "x86_64" ]; then
    require_config_line 'CONFIG_HYPERV_TIMER=y' 'CONFIG_HYPERV_TIMER is not enabled.'
  fi
  require_config_line 'CONFIG_HYPERV_UTILS=m' 'CONFIG_HYPERV_UTILS is not module-enabled.'
  require_config_line 'CONFIG_HYPERV_BALLOON=m' 'CONFIG_HYPERV_BALLOON is not module-enabled.'
  require_config_line 'CONFIG_HYPERV_NET=m' 'CONFIG_HYPERV_NET is not module-enabled.'
  require_config_line 'CONFIG_HYPERV_STORAGE=m' 'CONFIG_HYPERV_STORAGE is not module-enabled.'
  require_config_line 'CONFIG_HYPERV_KEYBOARD=m' 'CONFIG_HYPERV_KEYBOARD is not module-enabled.'
  require_config_line 'CONFIG_HID_HYPERV_MOUSE=m' 'CONFIG_HID_HYPERV_MOUSE is not module-enabled.'
  require_config_line 'CONFIG_PCI_HYPERV=m' 'CONFIG_PCI_HYPERV is not module-enabled.'
  require_config_line 'CONFIG_PCI_HYPERV_INTERFACE=m' 'CONFIG_PCI_HYPERV_INTERFACE is not module-enabled.'
  require_config_line 'CONFIG_DRM_HYPERV=m' 'CONFIG_DRM_HYPERV is not module-enabled.'
  require_config_line 'CONFIG_HYPERV_VSOCKETS=m' 'CONFIG_HYPERV_VSOCKETS is not module-enabled.'

  grep -E 'CONFIG_(DEBUG_INFO_NONE|TCP_CONG_BBR|DEFAULT_BBR|DEFAULT_TCP_CONG|NET_SCH_DEFAULT|NET_SCH_FQ|NET_SCH_FQ_CODEL|NET_SCH_PIE|NET_SCH_FQ_PIE|NET_SCH_CAKE|DEFAULT_FQ|DEFAULT_NET_SCH|NETFILTER_XTABLES_LEGACY|IP_NF_IPTABLES_LEGACY|IP_NF_NAT|IP_NF_FILTER|IP_NF_TARGET_MASQUERADE|IP6_NF_IPTABLES_LEGACY|IP6_NF_NAT|IP6_NF_FILTER|HYPERV|HYPERV_TIMER|HYPERV_UTILS|HYPERV_BALLOON|HYPERV_NET|HYPERV_STORAGE|HYPERV_KEYBOARD|HID_HYPERV_MOUSE|PCI_HYPERV|PCI_HYPERV_INTERFACE|DRM_HYPERV|HYPERV_VSOCKETS)=' .config
}

case "$arch" in
  arm64)
    cp "$workspace/arm64.config" .config
    ;;
  x86_64)
    cp "$workspace/x86-64.config" .config
    ;;
  *)
    echo "ERROR: unsupported arch: $arch"
    exit 1
    ;;
esac

apply_policy_config
run_olddefconfig
apply_policy_config
run_olddefconfig
validate_config

mkdir -p "$workspace/build-configs"
cp .config "$workspace/build-configs/${arch}.config"
kernel_version="${KERNEL_VERSION:-}"
if [ -z "$kernel_version" ]; then
  kernel_version="$(make -s kernelversion 2>/dev/null || true)"
fi
if [ -n "$kernel_version" ]; then
  cp .config "$workspace/build-configs/${arch}-${kernel_version}.config"
fi
