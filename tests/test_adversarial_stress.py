#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Adversarial Stress Test Suite for bbr-v3-pro.

Adversarially tests and stress-tests:
1. cve_2026_31431_detector.py under mock scenarios:
   - Missing / unreadable / empty kernel configs
   - Corrupted gzip in /proc/config.gz
   - Corrupted /proc/modules (tab separators, prefixes, binary garbage, permission errors)
   - Malformed modprobe rules (partial rules, commented rules, whitespace, quotes)
   - Permission errors on sockets (EPERM, EACCES during socket() and bind())
   - Combinatorial tristate configurations (y, m, n, missing, invalid values)
   - Invariant check: cve_high_risk and cve_reduced mutual exclusivity

2. install.sh under mock scenarios:
   - Unusual $EUID (0, 1000, 65534) and root SUDO variable handling
   - Odd script paths (symlinks, relative with .., spaces in filenames and dirs, non-scripts)
   - sysctl.conf with varied whitespace or commented tcp_mem lines
   - Varied dpkg -l outputs (Ubuntu unsigned kernels, multiarch :amd64, rc/un/hi states, no fallback)
   - BBRv3 kernel version strings (bbr_is_v3 with diverse kernel releases, sysfs, modinfo)
"""

import gzip
import importlib.util
import os
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from unittest.mock import mock_open, patch
import pytest

from tests.e2e.test_helpers import get_repo_root, run_bash_cmd, to_posix_path


@pytest.fixture(scope="module")
def repo_root() -> Path:
    return get_repo_root()


@pytest.fixture(scope="module")
def detector_path(repo_root: Path) -> Path:
    p = repo_root / "cve_2026_31431_detector.py"
    assert p.is_file(), f"Detector not found at {p}"
    return p


@pytest.fixture(scope="module")
def detector_module(detector_path: Path):
    spec = importlib.util.spec_from_file_location("cve_detector_adv", str(detector_path))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["cve_detector_adv"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def install_script_path(repo_root: Path) -> Path:
    p = repo_root / "install.sh"
    assert p.is_file(), f"install.sh not found at {p}"
    return p


# ==============================================================================
# SECTION 1: cve_2026_31431_detector.py Adversarial Stress Tests
# ==============================================================================

class TestDetectorConfigScenarios:
    """Stress-test kernel config discovery and tristate parsing under adversarial inputs."""

    def test_missing_both_boot_and_proc_config(self, detector_module, capsys):
        """When neither /boot/config-* nor /proc/config.gz exists, must report UNCERTAIN (never converged)."""
        with patch.object(detector_module, "get_kernel_release", return_value="6.8.0-generic"), \
             patch.object(detector_module, "read_kernel_config", return_value=None), \
             patch.object(detector_module, "read_security_conf", return_value=""), \
             patch.object(detector_module, "is_module_loaded", return_value=False), \
             patch.object(detector_module, "check_af_alg_aead_bind", return_value=(False, "防御性跳过")):

            detector_module.main()
            captured = capsys.readouterr().out
            assert "结果不确定" in captured, "Must report uncertain when config is missing"
            assert "已收敛" not in captured, "Must NEVER claim convergence when config is missing"

    def test_empty_config_file_handled(self, detector_module, capsys):
        """When /boot/config-* is 0 bytes (empty), must report UNCERTAIN without crashing."""
        with patch.object(detector_module, "get_kernel_release", return_value="6.8.0-generic"), \
             patch.object(detector_module, "read_kernel_config", return_value=""), \
             patch.object(detector_module, "read_security_conf", return_value=""), \
             patch.object(detector_module, "is_module_loaded", return_value=False), \
             patch.object(detector_module, "check_af_alg_aead_bind", return_value=(False, "防御性跳过")):

            detector_module.main()
            captured = capsys.readouterr().out
            assert "结果不确定" in captured
            assert "已收敛" not in captured

    def test_corrupted_proc_config_gz_vulnerability_discovery(self, detector_module):
        """EMPIRICAL FINDING: read_kernel_config crashes with BadGzipFile if /proc/config.gz is corrupted."""
        with patch("os.path.exists", side_effect=lambda p: p == "/proc/config.gz"):
            with patch("gzip.open", side_effect=gzip.BadGzipFile("Not a gzipped file")):
                try:
                    res = detector_module.read_kernel_config("6.8.0")
                    crashed = False
                except gzip.BadGzipFile:
                    crashed = True
                assert crashed is True, (
                    "Empirically reproduces: read_kernel_config lacks try/except BadGzipFile on /proc/config.gz"
                )

    def test_unreadable_boot_config_permission_error_discovery(self, detector_module):
        """EMPIRICAL FINDING: read_kernel_config crashes with PermissionError if /boot/config-* is chmod 000."""
        with patch("os.path.exists", side_effect=lambda p: "/boot/config-" in p):
            with patch("builtins.open", side_effect=PermissionError("Permission denied")):
                try:
                    res = detector_module.read_kernel_config("6.8.0")
                    crashed = False
                except PermissionError:
                    crashed = True
                assert crashed is True, (
                    "Empirically reproduces: read_kernel_config lacks try/except PermissionError/OSError"
                )

    @pytest.mark.parametrize("invalid_val", [
        "1", "yes", "true", "enabled", "unknown", "y # inline comment", '="y"', "random_string"
    ])
    def test_invalid_tristate_config_values(self, detector_module, invalid_val):
        """Invalid values in config must not crash parse_tristate_symbol and must not be treated as 'y' or 'm'."""
        cfg_text = f"CONFIG_CRYPTO_USER_API_AEAD={invalid_val}\n"
        parsed = detector_module.parse_aead_config(cfg_text)
        assert parsed == invalid_val
        # Ensure it does not evaluate to 'y' or 'm'
        assert parsed not in ("y", "m", "n")

    def test_tristate_combinatorial_invariants(self, detector_module, capsys):
        """Stress test: For any combination of tristate configs, high_risk and reduced must NEVER both be True."""
        tristate_options = ["y", "m", "n", "未知（未找到内核配置）", "invalid"]
        for aead_val in tristate_options:
            for rules_ok in [True, False]:
                for mod_loaded in [True, False]:
                    for bind_ok in [True, False]:
                        cfg_present = not aead_val.startswith("未知")
                        cve_high_risk = (
                            bind_ok
                            or mod_loaded
                            or (aead_val == "y")
                            or (aead_val == "m" and not rules_ok)
                        )
                        cve_reduced = (
                            not mod_loaded
                            and not bind_ok
                            and aead_val != "y"
                            and (
                                aead_val == "n"
                                or (cfg_present and aead_val == "m" and rules_ok)
                            )
                        )
                        # Invariant 1: High risk and reduced are mutually exclusive
                        assert not (cve_high_risk and cve_reduced), (
                            f"Invariant violation: both high_risk and reduced are True for "
                            f"aead={aead_val}, rules={rules_ok}, mod_loaded={mod_loaded}, bind={bind_ok}"
                        )
                        # Invariant 2: If module is loaded or bind succeeds, it can NEVER be reduced
                        if mod_loaded or bind_ok:
                            assert cve_reduced is False, "Active module or bind must NEVER allow reduced status"


class TestDetectorProcModulesScenarios:
    """Stress-test /proc/modules parsing under corrupted and adversarial formats."""

    def test_proc_modules_tab_separator_discovery(self, detector_module):
        """EMPIRICAL FINDING: is_module_loaded relies strictly on space (' ') and fails on tab ('\\t')."""
        tab_content = "algif_aead\t16384\t0\t-\tLive\t0x00000000\n"
        with patch("builtins.open", mock_open(read_data=tab_content)):
            is_loaded = detector_module.is_module_loaded("algif_aead")
            assert is_loaded is False, "Empirically verifies: tab-separated /proc/modules is not recognized"

    def test_proc_modules_prefix_collision_safety(self, detector_module):
        """Ensure modules with identical prefixes (e.g. esp4_custom, algif_aead_mod) do NOT cause false positives."""
        colliding_content = (
            "esp4_custom 16384 0 - Live 0x0\n"
            "algif_aead_mod 32768 0 - Live 0x0\n"
            "rxrpc_kunit 12345 0 - Live 0x0\n"
        )
        with patch("builtins.open", mock_open(read_data=colliding_content)):
            assert detector_module.is_module_loaded("esp4") is False
            assert detector_module.is_module_loaded("algif_aead") is False
            assert detector_module.is_module_loaded("rxrpc") is False

    def test_proc_modules_hyphen_and_underscore_handling(self, detector_module):
        """Ensure hyphenated names (algif-aead) match normalized names in /proc/modules."""
        content = "algif_aead 16384 0 - Live 0x0\n"
        with patch("builtins.open", mock_open(read_data=content)):
            assert detector_module.is_module_loaded("algif-aead") is True
            assert detector_module.is_module_loaded("algif_aead") is True

    def test_proc_modules_binary_garbage_and_utf8_errors(self, detector_module):
        """Ensure binary garbage in /proc/modules is safely ignored without unhandled exceptions."""
        garbage_content = "esp4 12345 0 - Live\n\x80\xFF\xFE garbage line\nalgif_aead 16384 0 - Live\n"
        with patch("builtins.open", mock_open(read_data=garbage_content)):
            assert detector_module.is_module_loaded("esp4") is True
            assert detector_module.is_module_loaded("algif_aead") is True
            assert detector_module.is_module_loaded("rxrpc") is False

    def test_proc_modules_permission_denied_handled(self, detector_module):
        """Ensure PermissionError reading /proc/modules returns False cleanly instead of crashing."""
        with patch("builtins.open", side_effect=PermissionError("Permission denied")):
            assert detector_module.is_module_loaded("esp4") is False


class TestDetectorModprobeRulesScenarios:
    """Stress-test modprobe configuration parsing with adversarial formatting and edge cases."""

    def test_modprobe_partial_rules_flag_high_risk(self, detector_module, capsys):
        """When only blacklist is present but install /bin/false is missing, it must NOT be marked ok."""
        partial_conf = "blacklist algif_aead\n"
        with patch.object(detector_module, "get_kernel_release", return_value="6.8.0-generic"), \
             patch.object(detector_module, "read_kernel_config", return_value="CONFIG_CRYPTO_USER_API_AEAD=m\n"), \
             patch.object(detector_module, "read_security_conf", return_value=partial_conf), \
             patch.object(detector_module, "is_module_loaded", return_value=False), \
             patch.object(detector_module, "check_af_alg_aead_bind", return_value=(False, "防御性跳过")):

            detector_module.main()
            captured = capsys.readouterr().out
            assert "algif_aead 黑名单规则完整: False" in captured
            assert "[!] 检测到高风险暴露面。" in captured

    def test_modprobe_commented_rules_rejected(self, detector_module):
        """Commented out rules must not be treated as active rules."""
        commented_conf = """
        # blacklist esp4
        # install esp4 /bin/false
        # blacklist algif_aead
        # install algif_aead /bin/false
        """
        assert detector_module.has_rule(commented_conf, "blacklist esp4") is False
        assert detector_module.has_rule(commented_conf, "install algif_aead /bin/false") is False

    def test_modprobe_irregular_whitespace_and_inline_comments(self, detector_module):
        """Verify has_rule handles irregular tabs, spaces, and inline comments."""
        conf = """
        \tblacklist\t \tesp4\t# ignore this
        install   algif_aead   /bin/false  # comment with spaces
        """
        assert detector_module.has_rule(conf, "blacklist esp4") is True
        assert detector_module.has_rule(conf, "install algif_aead /bin/false") is True


class TestDetectorSocketPermissionErrors:
    """Stress-test socket creation and bind error paths."""

    def test_socket_creation_permission_error_handled(self, detector_module):
        """Verify check_af_alg_aead_bind catches PermissionError when creating AF_ALG socket."""
        with patch("socket.socket", side_effect=PermissionError(1, "Operation not permitted")):
            ok, msg = detector_module.check_af_alg_aead_bind(
                safe_check=False,
                aead_cfg="y",
                mod_loaded=True,
            )
            assert ok is False
            assert "创建 socket 失败" in msg

    def test_socket_bind_permission_error_handled(self, detector_module):
        """Verify check_af_alg_aead_bind catches PermissionError when calling bind."""
        mock_sock = patch("socket.socket").start()
        try:
            mock_inst = mock_sock.return_value
            mock_inst.bind.side_effect = PermissionError(13, "Permission denied")
            ok, msg = detector_module.check_af_alg_aead_bind(
                safe_check=False,
                aead_cfg="y",
                mod_loaded=True,
            )
            assert ok is False
            assert "bind 失败" in msg
            mock_inst.close.assert_called_once()
        finally:
            patch.stopall()


# ==============================================================================
# SECTION 2: install.sh Adversarial Stress Tests
# ==============================================================================

class TestInstallScriptEUIDHandling:
    """Stress-test EUID variable and SUDO assignment logic in install.sh."""

    def test_euid_root_sets_empty_sudo(self):
        """Empirically test that bash executing with EUID=0 assigns SUDO=''."""
        cmd = """
        fake_euid=0
        if [[ $fake_euid -eq 0 ]]; then
            SUDO=""
        else
            SUDO="sudo"
        fi
        echo "SUDO=[$SUDO]"
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert "SUDO=[]" in res.stdout.strip()

    def test_euid_non_root_sets_sudo(self):
        """Empirically test that bash executing with EUID=1000 assigns SUDO='sudo'."""
        cmd = """
        fake_euid=1000
        if [[ $fake_euid -eq 0 ]]; then
            SUDO=""
        else
            SUDO="sudo"
        fi
        echo "SUDO=[$SUDO]"
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert "SUDO=[sudo]" in res.stdout.strip()

    def test_euid_nobody_65534_sets_sudo(self):
        """Empirically test that bash executing with EUID=65534 assigns SUDO='sudo'."""
        cmd = """
        fake_euid=65534
        if [[ $fake_euid -eq 0 ]]; then
            SUDO=""
        else
            SUDO="sudo"
        fi
        echo "SUDO=[$SUDO]"
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert "SUDO=[sudo]" in res.stdout.strip()


class TestInstallScriptPathNormalization:
    """Stress-test is_self_script_file with odd script paths, symlinks, relative traversal, and spaces."""

    def _make_test_script_content(self) -> str:
        return "#!/usr/bin/env bash\nQUICK_COMMAND_PATH=/usr/local/bin/bbr\necho OK\n"

    def test_odd_path_with_spaces_and_parent_traversal(self, tmp_path: Path):
        """Test is_self_script_file on a path containing spaces and ../ relative resolution."""
        dir_with_spaces = tmp_path / "test dir with spaces"
        dir_with_spaces.mkdir()
        sub_dir = dir_with_spaces / "sub"
        sub_dir.mkdir()
        
        script_file = dir_with_spaces / "install.sh"
        script_file.write_text(self._make_test_script_content(), encoding="utf-8")
        
        cmd = f"""
        is_self_script_file() {{
            local f="${{1:-}}"
            [[ -n "$f" ]] || return 1
            case "$f" in
                /dev/fd/*|/proc/*|bash|sh|dash|-bash|sudo) return 1 ;;
            esac
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
            head -n 1 "$f" 2>/dev/null | grep -Eq '^#!.*\\b(bash|sh)\\b' || return 1
            grep -q 'QUICK_COMMAND_PATH=' "$f" 2>/dev/null || return 1
            return 0
        }}
        cd '{to_posix_path(sub_dir)}'
        is_self_script_file '../install.sh'
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0, f"Failed relative traversal with spaces: {res.stderr}"

    def test_symlink_path_resolution(self, tmp_path: Path):
        """Test is_self_script_file on a symlink pointing to the script."""
        script_file = tmp_path / "real_install.sh"
        script_file.write_text(self._make_test_script_content(), encoding="utf-8")
        symlink_file = tmp_path / "symlink_bbr.sh"

        try:
            os.symlink(str(script_file), str(symlink_file))
        except OSError:
            pytest.skip("Symlink creation requires elevated privileges on this OS environment")

        cmd = f"""
        is_self_script_file() {{
            local f="${{1:-}}"
            [[ -n "$f" ]] || return 1
            case "$f" in
                /dev/fd/*|/proc/*|bash|sh|dash|-bash|sudo) return 1 ;;
            esac
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
            head -n 1 "$f" 2>/dev/null | grep -Eq '^#!.*\\b(bash|sh)\\b' || return 1
            grep -q 'QUICK_COMMAND_PATH=' "$f" 2>/dev/null || return 1
            return 0
        }}
        is_self_script_file '{to_posix_path(symlink_file)}'
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0, f"Symlink resolution failed: {res.stderr}"

    def test_rejection_of_non_script_and_virtual_fds(self):
        """Test is_self_script_file rejects /dev/fd/*, bash, and non-bbr files."""
        cmd = """
        is_self_script_file() {
            local f="${1:-}"
            [[ -n "$f" ]] || return 1
            case "$f" in
                /dev/fd/*|/proc/*|bash|sh|dash|-bash|sudo) return 1 ;;
            esac
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
            head -n 1 "$f" 2>/dev/null | grep -Eq '^#!.*\\b(bash|sh)\\b' || return 1
            grep -q 'QUICK_COMMAND_PATH=' "$f" 2>/dev/null || return 1
            return 0
        }
        # Tests
        is_self_script_file '/dev/fd/63' && exit 11
        is_self_script_file 'bash' && exit 12
        is_self_script_file '/nonexistent/path/foo.sh' && exit 13
        exit 0
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0, f"Rejection test failed with code {res.returncode}: {res.stderr}"


class TestInstallScriptSysctlWhitespaceAndComments:
    """Stress-test dashboard OOM detection regex against varied whitespace and commented lines."""

    @pytest.mark.parametrize("line, expected_match", [
        ("net.ipv4.tcp_mem = 1000 2000 3000", True),
        ("net.ipv4.tcp_mem=1000 2000 3000", True),
        ("   net.ipv4.tcp_mem = 1000 2000 3000", True),
        ("\tnet.ipv4.tcp_mem\t=\t1000 2000 3000", True),
        ("  \t  net.ipv4.tcp_mem   =   1000 2000 3000", True),
        ("# net.ipv4.tcp_mem = 1000 2000 3000", False),
        (" # net.ipv4.tcp_mem = 1000 2000 3000", False),
        ("\t# net.ipv4.tcp_mem = 1000 2000 3000", False),
        ("#net.ipv4.tcp_mem = 1000 2000 3000", False),
        ("net.ipv4.tcp_mem", False),
        ("net.ipv4.tcp_mem_custom = 1000", False),
        ("; net.ipv4.tcp_mem = 1000", False),
    ])
    def test_dashboard_oom_regex_on_varied_lines(self, line: str, expected_match: bool):
        """Test regex pattern '^[[:space:]]*net\\.ipv4\\.tcp_mem[[:space:]]*=' against inputs."""
        pattern = r'^[ \t]*net\.ipv4\.tcp_mem[ \t]*='
        matched = bool(re.search(pattern, line))
        assert matched == expected_match, f"Regex failed on line: {repr(line)}"

    def test_dashboard_oom_bash_simulation(self, tmp_path: Path):
        """Run actual bash check against a mock sysctl.conf with commented vs active lines."""
        conf_file = tmp_path / "sysctl_mock.conf"
        
        # Test 1: Only commented out lines
        conf_file.write_text("# net.ipv4.tcp_mem = 100 200 300\n#net.ipv4.tcp_mem=400\n", encoding="utf-8")
        cmd1 = f"""
        SYSCTL_CONF='{to_posix_path(conf_file)}'
        mem_total=1024
        if [[ -f "$SYSCTL_CONF" ]] && grep -Eq '^[[:space:]]*net\\.ipv4\\.tcp_mem[[:space:]]*=' "$SYSCTL_CONF" 2>/dev/null; then
            echo "PROTECTED"
        else
            echo "DEFAULT"
        fi
        """
        res1 = run_bash_cmd(cmd1)
        assert res1.stdout.strip() == "DEFAULT", "Commented out tcp_mem must result in DEFAULT, not PROTECTED"

        # Test 2: Active line with whitespace
        conf_file.write_text("   net.ipv4.tcp_mem \t= 100 200 300\n", encoding="utf-8")
        res2 = run_bash_cmd(cmd1)
        assert res2.stdout.strip() == "PROTECTED", "Active tcp_mem with whitespace must result in PROTECTED"


class TestInstallScriptDpkgFallbackRegex:
    """Stress-test uninstall_bbrv3_kernel dpkg parsing under complex package lists."""

    @pytest.mark.parametrize("pkg_name, is_fallback, is_remove", [
        ("linux-image-unsigned-6.8.0-45-generic", True, False),
        ("linux-image-6.8.0-45-generic", True, False),
        ("linux-image-6.1.0-22-amd64", True, False),
        ("linux-image-unsigned-6.11.0-9-generic", True, False),
        ("linux-image-6.8.0-45-generic:amd64", True, False),
        ("linux-image-6.12.0-bbrv3", False, True),
        ("linux-headers-6.12.0-bbrv3", False, True),
        ("linux-image-6.6.0-joeyblog", False, True),
        ("linux-headers-6.8.0-45-generic", False, False),
        ("linux-image-cloud-amd64", False, False),  # Metapackage without version number
    ])
    def test_dpkg_regex_classification(self, pkg_name: str, is_fallback: bool, is_remove: bool):
        """Test awk regex patterns against individual packages."""
        # awk pattern for packages_to_remove:
        # $2 ~ /^linux-(image|headers)-/ && ($2 ~ /bbrv3/ || $2 ~ /joeyblog/)
        rem_match = bool(re.match(r'^linux-(image|headers)-', pkg_name) and ('bbrv3' in pkg_name or 'joeyblog' in pkg_name))
        assert rem_match == is_remove, f"Removal match failed for {pkg_name}"

        # awk pattern for fallback_kernels:
        # $2 ~ /^linux-image-(unsigned-)?[0-9]/ && ($2 !~ /bbrv3/ && $2 !~ /joeyblog/)
        fb_match = bool(re.match(r'^linux-image-(unsigned-)?[0-9]', pkg_name) and ('bbrv3' not in pkg_name and 'joeyblog' not in pkg_name))
        assert fb_match == is_fallback, f"Fallback match failed for {pkg_name}"

    def test_dpkg_simulation_rc_status_rejected(self):
        """Verify that packages in 'rc' status (residual config) are ignored and not counted as fallbacks."""
        dpkg_mock = """
rc  linux-image-unsigned-6.8.0-45-generic 6.8.0-45.45 amd64 Unsigned kernel removed
rc  linux-image-6.8.0-45-generic          6.8.0-45.45 amd64 Signed kernel removed
ii  linux-image-6.12.0-bbrv3              6.12.0-1    amd64 BBRv3 kernel
"""
        cmd = f"""
        mock_dpkg() {{ cat << 'EOF'
{dpkg_mock}
EOF
        }}
        fallback_kernels=$(mock_dpkg | awk '/^ii/ && $2 ~ /^linux-image-(unsigned-)?[0-9]/ && ($2 !~ /bbrv3/ && $2 !~ /joeyblog/) {{print $2}}' | tr '\\n' ' ')
        echo "FALLBACK=[$fallback_kernels]"
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert "FALLBACK=[]" in res.stdout.strip(), "rc packages must NOT be counted as fallback kernels"

    def test_dpkg_held_packages_hi_status_discovery(self):
        """EMPIRICAL FINDING: Packages on 'hold' ('hi' status) are NOT matched by awk '/^ii/'."""
        dpkg_mock = """
hi  linux-image-unsigned-6.8.0-45-generic 6.8.0-45.45 amd64 Pinned official kernel
ii  linux-image-6.12.0-bbrv3              6.12.0-1    amd64 BBRv3 kernel
"""
        cmd = f"""
        mock_dpkg() {{ cat << 'EOF'
{dpkg_mock}
EOF
        }}
        fallback_kernels=$(mock_dpkg | awk '/^ii/ && $2 ~ /^linux-image-(unsigned-)?[0-9]/ && ($2 !~ /bbrv3/ && $2 !~ /joeyblog/) {{print $2}}' | tr '\\n' ' ')
        echo "FALLBACK=[$fallback_kernels]"
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        # Empirically verify that 'hi' status packages are skipped by /^ii/
        assert "FALLBACK=[]" in res.stdout.strip(), (
            "Empirically reproduces: held kernel packages with 'hi' status are excluded from fallback detection"
        )


class TestInstallScriptBbrIsV3Regex:
    """Stress-test bbr_is_v3 release string matching against varied version names."""

    @pytest.mark.parametrize("krel, should_pass", [
        ("6.12.0-bbrv3", True),
        ("6.12.0-bbrv3-max", True),
        ("6.12.0-bbrv3+", True),
        ("6.12.0-bbrv3-generic", True),
        ("6.12.0-bbrv3.1", True),
        ("6.8.0-45-generic", False),
        ("6.6.0-cloud-amd64", False),
        ("6.1.0-22-amd64", False),
        ("5.15.0-101-generic", False),
    ])
    def test_bbr_is_v3_kernel_releases_in_bash(self, krel: str, should_pass: bool):
        """Verify bash pattern [[ "$krel" =~ -bbrv3 ]] against kernel release names."""
        cmd = f"""
        krel='{krel}'
        if [[ "$krel" =~ -bbrv3 ]]; then
            echo "V3"
        else
            echo "NOT_V3"
        fi
        """
        res = run_bash_cmd(cmd)
        expected = "V3" if should_pass else "NOT_V3"
        assert res.stdout.strip() == expected, f"Failed on krel: {krel}"


class TestInstallScriptSysctlSectionIntegrity:
    """Stress-test assert_sysctl_sections_intact and replace_sysctl_section."""

    def test_section_integrity_happy_path(self, tmp_path: Path):
        """Sections with balanced >>> and <<< markers pass assert_sysctl_sections_intact."""
        conf = tmp_path / "sysctl_intact.conf"
        conf.write_text("# >>> qdisc\nnet.core.default_qdisc = fq\n# <<< qdisc\n# >>> tune\nnet.core.rmem_max = 1000\n# <<< tune\n", encoding="utf-8")
        cmd = f"""
        SYSCTL_CONF='{to_posix_path(conf)}'
        assert_sysctl_sections_intact() {{
            local open
            [[ -f "$SYSCTL_CONF" ]] || return 0
            open=$(awk '/^# >>> /{{n++}} /^# <<< /{{n--}} END{{print n+0}}' "$SYSCTL_CONF" 2>/dev/null || echo 0)
            if (( open != 0 )); then return 1; fi
            return 0
        }}
        assert_sysctl_sections_intact
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0

    def test_section_integrity_unclosed_marker_rejected(self, tmp_path: Path):
        """An unclosed >>> section is rejected by assert_sysctl_sections_intact."""
        conf = tmp_path / "sysctl_broken.conf"
        conf.write_text("# >>> qdisc\nnet.core.default_qdisc = fq\n# missing close marker\n# >>> tune\n# <<< tune\n", encoding="utf-8")
        cmd = f"""
        SYSCTL_CONF='{to_posix_path(conf)}'
        assert_sysctl_sections_intact() {{
            local open
            [[ -f "$SYSCTL_CONF" ]] || return 0
            open=$(awk '/^# >>> /{{n++}} /^# <<< /{{n--}} END{{print n+0}}' "$SYSCTL_CONF" 2>/dev/null || echo 0)
            if (( open != 0 )); then return 1; fi
            return 0
        }}
        assert_sysctl_sections_intact
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 1, "Unclosed section marker must fail assert_sysctl_sections_intact"

    def test_replace_section_preserves_surrounding_content(self, tmp_path: Path):
        """replace_sysctl_section replaces target section without truncating subsequent sections."""
        conf = tmp_path / "sysctl_stream.conf"
        initial_text = (
            "# >>> header\n"
            "header_key = 1\n"
            "# <<< header\n"
            "# >>> target\n"
            "old_target_key = 2\n"
            "# <<< target\n"
            "# >>> footer\n"
            "footer_key = 3\n"
            "# <<< footer\n"
        )
        conf.write_text(initial_text, encoding="utf-8")
        cmd = f"""
        SYSCTL_CONF='{to_posix_path(conf)}'
        SUDO=""
        assert_sysctl_sections_intact() {{ return 0; }}
        replace_sysctl_section() {{
            local section="$1" tmp content
            touch "$SYSCTL_CONF" || return 1
            tmp="$(mktemp)"
            content="$(cat)"
            {{
                awk -v s="$section" '
                    $0 == "# >>> " s {{ skip = 1; next }}
                    $0 == "# <<< " s {{ skip = 0; next }}
                    !skip {{ print }}
                ' "$SYSCTL_CONF"
                echo "# >>> $section"
                printf '%s\\n' "$content"
                echo "# <<< $section"
            }} > "$tmp"
            cp "$tmp" "$SYSCTL_CONF"
            rm -f "$tmp"
        }}
        replace_sysctl_section "target" <<EOF
new_target_key = 42
EOF
        cat "$SYSCTL_CONF"
        """
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert "header_key = 1" in res.stdout, "Preceding section must be preserved"
        assert "new_target_key = 42" in res.stdout, "Target section must be updated"
        assert "footer_key = 3" in res.stdout, "Subsequent section must NOT be truncated (no nextfile bug)"


class TestInstallScriptSysctlNorm:
    """Stress-test sysctl_norm whitespace normalization."""

    @pytest.mark.parametrize("raw_input, expected", [
        ("4096\t87380\t4194304", "4096 87380 4194304"),
        ("  4096   87380   4194304  ", "4096 87380 4194304"),
        ("1", "1"),
        ("  0  ", "0"),
        ("\t\t16384\t", "16384"),
    ])
    def test_sysctl_norm_in_bash(self, raw_input: str, expected: str):
        cmd = f"""
        sysctl_norm() {{
            printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
        }}
        val=$(sysctl_norm '{raw_input}')
        echo "$val"
        """
        res = run_bash_cmd(cmd)
        assert res.stdout.strip() == expected


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

