#!/usr/bin/env bash
set -euo pipefail

tree_dir="${1:-.}"
cd "$tree_dir"

target="scripts/package/install-extmod-build"
if [[ ! -f "$target" ]]; then
  echo "ERROR: run prepare-kernel-packaging.sh inside a kernel source tree." >&2
  exit 1
fi

# Mainline install-extmod-build strips .config and keeps only include/config/auto.conf,
# but third-party DKMS modules still inspect /lib/modules/<ver>/build/.config.
if ! grep -q 'BBRV3_HEADERS_CONFIG' "$target"; then
  cat >> "$target" <<'EOF'

# BBRV3_HEADERS_CONFIG: preserve complete .config in linux-headers package for DKMS compatibility.
cp "${KCONFIG_CONFIG:-.config}" "${destdir}/.config"
EOF
fi
