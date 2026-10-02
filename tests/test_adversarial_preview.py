"""Adversarial stress-test suite for teamwork_preview_challenger_1.

Empirically tests and stress-tests:
1. Patch sorting resilience with complex and unusual paths (hyphens, numbers, dots, spaces, special chars).
2. scripts/prepare-kernel-config.sh behavior under corrupted/missing env vars, read-only dirs, and unsupported archs.
3. .github/workflows/build.yml YAML schema validity, missing inputs, and boundary input injection.
4. Hyper-V kernel configuration symbols consistency between x86-64 and arm64, and dependency closure.
"""

import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Dict, List, Optional
import pytest
import yaml

from tests.e2e.test_helpers import (
    get_bash_path,
    get_repo_root,
    load_yaml_file,
    parse_kconfig_file,
    run_bash_cmd,
    run_bash_script,
    to_posix_path,
)


@pytest.fixture(scope="module")
def repo_root() -> Path:
    return get_repo_root()


@pytest.fixture(scope="module")
def x86_config(repo_root: Path) -> Dict[str, str]:
    return parse_kconfig_file(repo_root / "x86-64.config")


@pytest.fixture(scope="module")
def arm64_config(repo_root: Path) -> Dict[str, str]:
    return parse_kconfig_file(repo_root / "arm64.config")


@pytest.fixture(scope="module")
def build_workflow_yaml(repo_root: Path) -> dict:
    return load_yaml_file(repo_root / ".github" / "workflows" / "build.yml")


# ==============================================================================
# 1. Adversarial Patch Sorting Stress Tests
# ==============================================================================

class TestPatchSortingAdversarial:
    """Stress-test the patch sorting logic in scripts/apply-bbrv3-port.sh."""

    def test_hyphen_heavy_directory_paths(self):
        """Test sort -V when directory paths contain varying numbers of hyphens."""
        paths = [
            "/var/build-sub-system-1-2-3/my-bbr-v3-project/patches/bbrv3-linux-6.1.patch",
            "/var/build-sub-system-1-2-3/my-bbr-v3-project/patches/bbrv3-linux-6.6.patch",
            "/var/build-sub-system-1-2-3/my-bbr-v3-project/patches/bbrv3-linux-6.10.patch",
            "/var/build-sub-system-1-2-3/my-bbr-v3-project/patches/bbrv3-linux-6.12.patch",
        ]
        input_data = "\n".join(paths)
        cmd = f"printf '%s\\n' '{input_data}' | sort -V | tail -n 1"
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert res.stdout.strip().endswith("bbrv3-linux-6.12.patch")

    def test_numbers_in_parent_directories_higher_than_kernel_version(self):
        """Parent directory contains numbers (e.g. 99.9.99) higher than kernel versions."""
        paths = [
            "/opt/kernel-99.9.99-custom.build/patches/bbrv3-linux-6.1.patch",
            "/opt/kernel-99.9.99-custom.build/patches/bbrv3-linux-6.6.patch",
            "/opt/kernel-99.9.99-custom.build/patches/bbrv3-linux-6.10.patch",
            "/opt/kernel-99.9.99-custom.build/patches/bbrv3-linux-6.12.patch",
        ]
        input_data = "\n".join(paths)
        cmd = f"printf '%s\\n' '{input_data}' | sort -V | tail -n 1"
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert res.stdout.strip().endswith("bbrv3-linux-6.12.patch")

    def test_complex_semver_patch_versions(self):
        """Test ordering across major version jumps, multi-digit minors, and sublevels."""
        paths = [
            "patches/bbrv3-linux-5.15.patch",
            "patches/bbrv3-linux-6.1.patch",
            "patches/bbrv3-linux-6.2.patch",
            "patches/bbrv3-linux-6.6.patch",
            "patches/bbrv3-linux-6.9.patch",
            "patches/bbrv3-linux-6.10.patch",
            "patches/bbrv3-linux-6.12.patch",
            "patches/bbrv3-linux-7.0.patch",
            "patches/bbrv3-linux-7.1.patch",
            "patches/bbrv3-linux-7.10.patch",
        ]
        input_data = "\n".join(paths)
        cmd = f"printf '%s\\n' '{input_data}' | sort -V | tail -n 1"
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert res.stdout.strip() == "patches/bbrv3-linux-7.10.patch"

    def test_sublevel_and_rc_patch_versions(self):
        """Test sublevels (6.6 vs 6.6.1 vs 6.6.10)."""
        paths = [
            "patches/bbrv3-linux-6.6.patch",
            "patches/bbrv3-linux-6.6.1.patch",
            "patches/bbrv3-linux-6.6.2.patch",
            "patches/bbrv3-linux-6.6.10.patch",
        ]
        input_data = "\n".join(paths)
        cmd = f"printf '%s\\n' '{input_data}' | sort -V | tail -n 1"
        res = run_bash_cmd(cmd)
        assert res.returncode == 0
        assert res.stdout.strip() == "patches/bbrv3-linux-6.6.10.patch"

    def test_spaces_and_special_chars_in_directory(self):
        """Test directory paths containing spaces, underscores, dots, and hyphens."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            special_dir = Path(tmp_dir) / "build path with spaces-v1.0_rc.1"
            patches_dir = special_dir / "patches"
            patches_dir.mkdir(parents=True)

            (patches_dir / "bbrv3-linux-6.6.patch").write_text("patch6.6")
            (patches_dir / "bbrv3-linux-6.12.patch").write_text("patch6.12")
            (patches_dir / "bbrv3-linux-6.1.patch").write_text("patch6.1")

            posix_patches = to_posix_path(patches_dir)
            cmd = f'ls "{posix_patches}"/bbrv3-linux-*.patch 2>/dev/null | sort -V | tail -n 1'
            res = run_bash_cmd(cmd)
            assert res.returncode == 0
            assert "bbrv3-linux-6.12.patch" in res.stdout

    def test_script_execution_in_hyphenated_path_fallback(self, repo_root: Path):
        """Simulate execution of apply-bbrv3-port.sh in an environment with missing target patch."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            hyphen_repo = Path(tmp_dir) / "my-hyphen-bbr-v3-root.1.2.3"
            scripts_dir = hyphen_repo / "scripts"
            patches_dir = hyphen_repo / "patches"
            scripts_dir.mkdir(parents=True)
            patches_dir.mkdir(parents=True)

            # Copy apply-bbrv3-port.sh
            src_script = repo_root / "scripts" / "apply-bbrv3-port.sh"
            target_script = scripts_dir / "apply-bbrv3-port.sh"
            target_script.write_text(src_script.read_text(encoding="utf-8"), encoding="utf-8")

            # Create patches: 6.6 and 6.12
            (patches_dir / "bbrv3-linux-6.6.patch").write_text("diff 6.6")
            (patches_dir / "bbrv3-linux-6.12.patch").write_text("diff 6.12")

            # Create a mock Makefile requesting 7.1 (which doesn't exist, triggering fallback)
            makefile_content = "VERSION = 7\nPATCHLEVEL = 1\nSUBLEVEL = 0\n"
            (hyphen_repo / "Makefile").write_text(makefile_content)

            # Run apply-bbrv3-port.sh - expect fallback selection of 6.12
            res = run_bash_script(target_script, cwd=hyphen_repo)
            # Will fail at git apply since mock patch is not git repo, but stderr must log fallback to 6.12!
            assert "falling back to bbrv3-linux-6.12.patch" in res.stderr

    def test_missing_patches_directory_graceful_rejection(self, repo_root: Path):
        """When patches/ directory has zero patches, apply-bbrv3-port.sh must cleanly exit with error."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            test_repo = Path(tmp_dir) / "empty-repo"
            scripts_dir = test_repo / "scripts"
            patches_dir = test_repo / "patches"
            scripts_dir.mkdir(parents=True)
            patches_dir.mkdir(parents=True)

            src_script = repo_root / "scripts" / "apply-bbrv3-port.sh"
            target_script = scripts_dir / "apply-bbrv3-port.sh"
            target_script.write_text(src_script.read_text(encoding="utf-8"), encoding="utf-8")

            makefile_content = "VERSION = 7\nPATCHLEVEL = 1\nSUBLEVEL = 0\n"
            (test_repo / "Makefile").write_text(makefile_content)

            res = run_bash_script(target_script, cwd=test_repo)
            assert res.returncode != 0
            # Under set -e / pipefail or explicit check, must fail gracefully
            assert res.returncode in (1, 2)


# ==============================================================================
# 2. Adversarial prepare-kernel-config.sh Stress Tests
# ==============================================================================

class TestPrepareKernelConfigAdversarial:
    """Stress-test scripts/prepare-kernel-config.sh under adversarial conditions."""

    def test_missing_arch_argument_fails(self, repo_root: Path):
        """Calling script with no arguments must fail immediately with usage instructions."""
        script = repo_root / "scripts" / "prepare-kernel-config.sh"
        res = run_bash_script(script, args=[])
        assert res.returncode != 0
        assert "usage" in res.stderr.lower()

    def test_empty_arch_argument_fails(self, repo_root: Path):
        """Calling script with empty string arch must fail with usage or unsupported arch."""
        script = repo_root / "scripts" / "prepare-kernel-config.sh"
        res = run_bash_script(script, args=[""])
        assert res.returncode != 0

    @pytest.mark.parametrize("invalid_arch", [
        "riscv64",
        "i386",
        "amd64",
        "x86-64",  # Hyphen instead of underscore
        "ARM64",   # Uppercase
        "x86_32",
        "mips",
        "../../etc",
    ])
    def test_unsupported_architectures_rejected(self, repo_root: Path, invalid_arch: str):
        """Script must reject any architecture other than x86_64 or arm64."""
        script = repo_root / "scripts" / "prepare-kernel-config.sh"
        with tempfile.TemporaryDirectory() as tmp_dir:
            res = run_bash_script(script, args=[invalid_arch], cwd=tmp_dir)
            assert res.returncode != 0
            assert "unsupported arch" in res.stderr.lower() or "usage" in res.stderr.lower()

    def test_corrupted_github_workspace_fails(self, repo_root: Path):
        """When GITHUB_WORKSPACE points to a non-existent directory, script must fail cleanly."""
        script = repo_root / "scripts" / "prepare-kernel-config.sh"
        with tempfile.TemporaryDirectory() as tmp_dir:
            corrupted_workspace = "/nonexistent/corrupted/workspace/path"
            res = run_bash_script(
                script,
                args=["x86_64"],
                cwd=tmp_dir,
                env={"GITHUB_WORKSPACE": corrupted_workspace},
            )
            assert res.returncode != 0

    def test_read_only_build_configs_fails_safely(self, repo_root: Path):
        """When build-configs destination cannot be written, script aborts with non-zero exit code."""
        script = repo_root / "scripts" / "prepare-kernel-config.sh"
        with tempfile.TemporaryDirectory() as tmp_dir:
            # Set up mock workspace with valid x86-64.config
            ws = Path(tmp_dir) / "ws"
            ws.mkdir()
            shutil.copy(repo_root / "x86-64.config", ws / "x86-64.config")

            # Create build-configs as a non-directory file to block mkdir -p
            blocked_target = ws / "build-configs"
            blocked_target.write_text("blocking file")

            # Create mock scripts/config and make
            scripts_dir = Path(tmp_dir) / "scripts"
            scripts_dir.mkdir()
            mock_config = scripts_dir / "config"
            mock_config.write_text("#!/usr/bin/env bash\nexit 0\n")
            mock_config.chmod(0o755)

            bin_dir = Path(tmp_dir) / "bin"
            bin_dir.mkdir()
            mock_make = bin_dir / "make"
            mock_make.write_text("#!/usr/bin/env bash\nexit 0\n")
            mock_make.chmod(0o755)

            env = {
                "GITHUB_WORKSPACE": to_posix_path(ws),
                "PATH": f"{to_posix_path(bin_dir)}:{os.environ.get('PATH', '')}",
            }
            res = run_bash_script(script, args=["x86_64"], cwd=tmp_dir, env=env)
            assert res.returncode != 0

    def test_validation_aborts_on_forbidden_esp_symbols(self, repo_root: Path):
        """validate_config must reject .config if CONFIG_XFRM_ESP or INET_ESP is present."""
        script = repo_root / "scripts" / "prepare-kernel-config.sh"
        with tempfile.TemporaryDirectory() as tmp_dir:
            ws = Path(tmp_dir) / "ws"
            ws.mkdir()
            # Copy base config and append forbidden symbol
            cfg_text = (repo_root / "x86-64.config").read_text(encoding="utf-8")
            cfg_text += "\nCONFIG_XFRM_ESP=y\n"
            (ws / "x86-64.config").write_text(cfg_text, encoding="utf-8")

            # Create mock scripts/config (noop so forbidden symbol persists)
            scripts_dir = Path(tmp_dir) / "scripts"
            scripts_dir.mkdir()
            mock_config = scripts_dir / "config"
            mock_config.write_text("#!/usr/bin/env bash\nexit 0\n")
            mock_config.chmod(0o755)

            bin_dir = Path(tmp_dir) / "bin"
            bin_dir.mkdir()
            mock_make = bin_dir / "make"
            mock_make.write_text("#!/usr/bin/env bash\nexit 0\n")
            mock_make.chmod(0o755)

            env = {
                "GITHUB_WORKSPACE": to_posix_path(ws),
                "PATH": f"{to_posix_path(bin_dir)}:{os.environ.get('PATH', '')}",
            }
            res = run_bash_script(script, args=["x86_64"], cwd=tmp_dir, env=env)
            assert res.returncode != 0
            assert "is enabled; refusing to continue" in res.stdout or "is enabled; refusing to continue" in res.stderr

    def test_validation_aborts_on_missing_hyperv_symbol(self, repo_root: Path):
        """validate_config must reject .config if CONFIG_HYPERV is not enabled."""
        script = repo_root / "scripts" / "prepare-kernel-config.sh"
        with tempfile.TemporaryDirectory() as tmp_dir:
            ws = Path(tmp_dir) / "ws"
            ws.mkdir()
            # Strip CONFIG_HYPERV from config
            cfg_text = (repo_root / "x86-64.config").read_text(encoding="utf-8")
            cfg_text = re.sub(r"CONFIG_HYPERV=[^\n]*", "# CONFIG_HYPERV is not set", cfg_text)
            (ws / "x86-64.config").write_text(cfg_text, encoding="utf-8")

            # Create mock scripts/config (noop so stripped symbol remains missing)
            scripts_dir = Path(tmp_dir) / "scripts"
            scripts_dir.mkdir()
            mock_config = scripts_dir / "config"
            mock_config.write_text("#!/usr/bin/env bash\nexit 0\n")
            mock_config.chmod(0o755)

            bin_dir = Path(tmp_dir) / "bin"
            bin_dir.mkdir()
            mock_make = bin_dir / "make"
            mock_make.write_text("#!/usr/bin/env bash\nexit 0\n")
            mock_make.chmod(0o755)

            env = {
                "GITHUB_WORKSPACE": to_posix_path(ws),
                "PATH": f"{to_posix_path(bin_dir)}:{os.environ.get('PATH', '')}",
            }
            res = run_bash_script(script, args=["x86_64"], cwd=tmp_dir, env=env)
            assert res.returncode != 0
            assert "CONFIG_HYPERV is not module-enabled" in res.stdout or "CONFIG_HYPERV is not module-enabled" in res.stderr


# ==============================================================================
# 3. Adversarial build.yml Workflow Schema & Inputs Tests
# ==============================================================================

class TestBuildWorkflowAdversarial:
    """Stress-test .github/workflows/build.yml structure and input boundaries."""

    def test_strict_yaml_parsing(self, repo_root: Path):
        """Ensure build.yml parses with strict PyYAML SafeLoader without syntax errors."""
        workflow_file = repo_root / ".github" / "workflows" / "build.yml"
        with open(workflow_file, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        assert isinstance(data, dict)
        assert data.get("name") is not None
        assert "jobs" in data

    def test_workflow_dispatch_schema_completeness(self, build_workflow_yaml: dict):
        """Verify workflow_dispatch input keys, types, defaults, and descriptions."""
        triggers = build_workflow_yaml.get("on", {})
        dispatch = triggers.get("workflow_dispatch", {})
        inputs = dispatch.get("inputs", {})

        # force_rebuild
        assert "force_rebuild" in inputs
        assert inputs["force_rebuild"]["type"] == "boolean"
        assert inputs["force_rebuild"]["default"] is False
        assert len(inputs["force_rebuild"]["description"]) > 0

        # kernel_version
        assert "kernel_version" in inputs
        assert inputs["kernel_version"]["type"] == "string"
        assert inputs["kernel_version"]["default"] == ""
        assert len(inputs["kernel_version"]["description"]) > 0

    @pytest.mark.parametrize("input_ver,expected_result", [
        ("6.14.2", "6.14.2"),
        ("6.14", "6.14.0"),
        ("  6.14.2  ", "6.14.2"),
        ("v6.14.2", "6.14.2"),
        ("v6.14", "6.14.0"),
    ])
    def test_preflight_kernel_version_normalization(self, input_ver: str, expected_result: str):
        """Simulate preflight bash logic for valid kernel version normalization."""
        bash_snippet = f"""
        INPUT_KERNEL_VERSION="{input_ver}"
        user_kernel_version=$(echo "${{INPUT_KERNEL_VERSION:-}}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^v//')
        raw_version="$user_kernel_version"
        version="$raw_version"
        if [[ "$version" =~ ^[0-9]+\\.[0-9]+$ ]]; then
          version="${{version}}.0"
        fi
        if ! [[ "$version" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$ ]]; then
          exit 1
        fi
        echo "$version"
        """
        res = run_bash_cmd(bash_snippet)
        assert res.returncode == 0
        assert res.stdout.strip() == expected_result

    @pytest.mark.parametrize("adversarial_ver", [
        "6.14; reboot",
        "$(whoami)",
        "6.14.2-rc1",
        "6",
        "invalid_version",
        "6.14.2.1",
        "-6.14.2",
        "6.14..2",
    ])
    def test_preflight_kernel_version_adversarial_rejection(self, adversarial_ver: str):
        """Preflight bash regex must reject malicious or malformed kernel version strings."""
        bash_snippet = f"""
        INPUT_KERNEL_VERSION='{adversarial_ver}'
        user_kernel_version=$(echo "${{INPUT_KERNEL_VERSION:-}}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^v//')
        raw_version="$user_kernel_version"
        version="$raw_version"
        if [[ "$version" =~ ^[0-9]+\\.[0-9]+$ ]]; then
          version="${{version}}.0"
        fi
        if ! [[ "$version" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$ ]]; then
          exit 1
        fi
        """
        res = run_bash_cmd(bash_snippet)
        assert res.returncode == 1, f"Adversarial input '{adversarial_ver}' was not rejected"

    def test_branch_extraction_regex(self):
        """Test grep -oP '^\\d+\\.\\d+' extracts branch cleanly."""
        res = run_bash_cmd("echo '6.14.2' | grep -oP '^\\d+\\.\\d+'")
        assert res.returncode == 0
        assert res.stdout.strip() == "6.14"

        res2 = run_bash_cmd("echo '7.0.0' | grep -oP '^\\d+\\.\\d+'")
        assert res2.returncode == 0
        assert res2.stdout.strip() == "7.0"

    def test_update_config_baseline_has_no_naked_push(self, repo_root: Path):
        """Verify update-config-baseline never executes an unqualified 'git push'."""
        content = (repo_root / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
        job_content = content.split("update-config-baseline:")[1]

        # Lines starting with git push
        push_lines = [line.strip() for line in job_content.splitlines() if "git push" in line]
        assert len(push_lines) > 0, "Must contain git push"
        for line in push_lines:
            assert 'HEAD:${{ github.ref_name }}' in line or '${{ github.ref_name }}' in line, (
                f"Unsafe push command found: {line}"
            )


# ==============================================================================
# 4. Hyper-V Kernel Config Symbols & Dependency Parity Tests
# ==============================================================================

class TestHyperVConfigParityAdversarial:
    """Stress-test Hyper-V configuration symbols, arch parity, and dependency closure."""

    CORE_AND_COMPANION_HYPERV_DRIVERS = [
        ("CONFIG_HYPERV", "m"),
        ("CONFIG_HYPERV_TIMER", "y"),
        ("CONFIG_HYPERV_UTILS", "m"),
        ("CONFIG_HYPERV_BALLOON", "m"),
        ("CONFIG_HYPERV_NET", "m"),
        ("CONFIG_HYPERV_STORAGE", "m"),
        ("CONFIG_HYPERV_KEYBOARD", "m"),
        ("CONFIG_HID_HYPERV_MOUSE", "m"),
        ("CONFIG_PCI_HYPERV", "m"),
        ("CONFIG_PCI_HYPERV_INTERFACE", "m"),
        ("CONFIG_FB_HYPERV", "m"),
        ("CONFIG_DRM_HYPERV", "m"),
        ("CONFIG_HYPERV_VSOCKETS", "m"),
    ]

    def test_full_hyperv_symbol_set_presence_and_values(
        self, x86_config: Dict[str, str], arm64_config: Dict[str, str]
    ):
        """All core and companion Hyper-V symbols must be configured identically in x86 and arm64."""
        for sym, expected_val in self.CORE_AND_COMPANION_HYPERV_DRIVERS:
            x86_val = x86_config.get(sym)
            arm_val = arm64_config.get(sym)
            assert x86_val == expected_val, (
                f"x86-64.config: {sym} expected {expected_val}, got {x86_val}"
            )
            assert arm_val == expected_val, (
                f"arm64.config: {sym} expected {expected_val}, got {arm_val}"
            )

    def test_hyperv_kconfig_dependency_closure(
        self, x86_config: Dict[str, str], arm64_config: Dict[str, str]
    ):
        """Ensure all required subsystem dependencies for Hyper-V drivers are enabled."""
        required_dependencies = [
            ("CONFIG_ACPI", "y"),
            ("CONFIG_PCI", "y"),
            ("CONFIG_PCI_MSI", "y"),
            ("CONFIG_SCSI", ["y", "m"]),
            ("CONFIG_NETDEVICES", "y"),
            ("CONFIG_INPUT", ["y", "m"]),
            ("CONFIG_INPUT_KEYBOARD", "y"),
            ("CONFIG_HID", ["y", "m"]),
            ("CONFIG_VSOCKETS", ["y", "m"]),
            ("CONFIG_DRM", ["y", "m"]),
            ("CONFIG_FB", ["y", "m"]),
        ]

        for dep, allowed in required_dependencies:
            allowed_list = allowed if isinstance(allowed, list) else [allowed]
            for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
                actual = cfg.get(dep)
                assert actual in allowed_list, (
                    f"Subsystem dependency {dep} for Hyper-V missing or disabled in {arch_name} (got {actual}, expected one of {allowed_list})"
                )

    def test_hypervisor_guest_enlightenments(
        self, x86_config: Dict[str, str], arm64_config: Dict[str, str]
    ):
        """Verify guest enlightenments infrastructure."""
        # CONFIG_HYPERVISOR_GUEST is x86-specific
        assert x86_config.get("CONFIG_HYPERVISOR_GUEST") == "y"
        # CONFIG_SYS_HYPERVISOR is generic
        assert x86_config.get("CONFIG_SYS_HYPERVISOR") == "y"
        assert arm64_config.get("CONFIG_SYS_HYPERVISOR") == "y"

    def test_vulnerable_dirtyfrag_symbols_not_accidentally_reintroduced(
        self, x86_config: Dict[str, str], arm64_config: Dict[str, str]
    ):
        """Vulnerable networking and crypto symbols must remain disabled."""
        forbidden_symbols = [
            "CONFIG_XFRM_ESP",
            "CONFIG_INET_ESP",
            "CONFIG_INET6_ESP",
            "CONFIG_AF_RXRPC",
            "CONFIG_RXKAD",
        ]
        for sym in forbidden_symbols:
            for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
                val = cfg.get(sym, "n")
                assert val in ("n", None), (
                    f"Forbidden symbol {sym} is active ({val}) in {arch_name}"
                )


# ==============================================================================
# 5. Fuzzing Generator & Semantic Oracle Tests
# ==============================================================================

class TestPatchSortingFuzzerOracle:
    """Randomized property-based fuzzer testing patch sorting against an independent oracle."""

    @staticmethod
    def _parse_version(v_str: str) -> tuple:
        """Independent version parsing oracle."""
        parts = []
        for segment in re.split(r'[-.]', v_str):
            if segment.isdigit():
                parts.append((0, int(segment)))
            elif segment.startswith("rc") and segment[2:].isdigit():
                parts.append((-1, int(segment[2:])))
            else:
                parts.append((1, segment))
        return tuple(parts)

    def test_randomized_directory_path_fuzzing(self):
        """Fuzz with 50 randomly generated pathological directory names."""
        import random

        prefixes = [
            "/home/user-1/repo-bbr-v3",
            "/var/build.123/sub-456.789/bbr-v3-pro-main",
            "/tmp/path-with-numbers-99.9.99-beta.10",
            "/opt/app-v2.1.0/bbr-v3-pro-main-rc.3",
            "/scratch/run_100-build.0/nested-v1-v2-v3/dir.4.5.6",
            "/tmp/k8s-ci-1.28.0/worker-node-42",
            "/a-1/b-2.0/c-3.0.0/d-4/e-5.6.7",
        ]

        version_candidates = [
            "5.15", "6.1", "6.2", "6.5.1", "6.6", "6.6.1", "6.6.10",
            "6.9", "6.10", "6.11", "6.12", "6.14", "6.14.2", "7.0", "7.1", "7.10"
        ]

        random.seed(42)  # Deterministic seed for reproducible testing

        for i in range(50):
            prefix = random.choice(prefixes)
            # Pick a random subset of 4 to 8 versions
            sample_versions = random.sample(version_candidates, k=random.randint(4, 8))
            
            # Oracle determines the maximum version
            oracle_max = max(sample_versions, key=self._parse_version)

            # Generate full file paths
            paths = [f"{prefix}/patches/bbrv3-linux-{v}.patch" for v in sample_versions]
            random.shuffle(paths)  # Shuffle input order

            input_data = "\n".join(paths)
            cmd = f"printf '%s\\n' '{input_data}' | sort -V | tail -n 1"
            res = run_bash_cmd(cmd)

            assert res.returncode == 0, f"sort -V failed for iteration {i}"
            actual_chosen = res.stdout.strip()
            expected_chosen = f"{prefix}/patches/bbrv3-linux-{oracle_max}.patch"
            assert actual_chosen == expected_chosen, (
                f"Fuzzer mismatch at iteration {i}:\n"
                f"Input versions: {sample_versions}\n"
                f"Expected: {expected_chosen}\n"
                f"Got:      {actual_chosen}"
            )


# ==============================================================================
# 6. Workflow Job DAG & Configuration Matrix Tests
# ==============================================================================

class TestBuildWorkflowDAGAndMatrix:
    """Stress-test the CI workflow job dependency graph, runner assignments, and conditions."""

    def test_workflow_level_settings(self, build_workflow_yaml: dict):
        """Verify concurrency and permissions."""
        assert "concurrency" in build_workflow_yaml
        conc = build_workflow_yaml["concurrency"]
        assert conc.get("group") == "bbrv3-kernel-build"
        assert conc.get("cancel-in-progress") is True

        perms = build_workflow_yaml.get("permissions", {})
        assert perms.get("contents") == "write"
        assert perms.get("actions") == "write"

    def test_job_dependency_dag(self, build_workflow_yaml: dict):
        """Verify the DAG edges: preflight -> cleanup -> build -> update-config-baseline."""
        jobs = build_workflow_yaml["jobs"]
        
        # cleanup needs preflight
        assert jobs["cleanup"].get("needs") == "preflight"
        assert "build_needed == 'true'" in jobs["cleanup"].get("if", "")

        # build needs [preflight, cleanup]
        build_needs = jobs["build"].get("needs")
        assert "preflight" in build_needs and "cleanup" in build_needs
        assert "build_needed == 'true'" in jobs["build"].get("if", "")
        assert "cleanup.result == 'success'" in jobs["build"].get("if", "")

        # update-config-baseline needs [preflight, build]
        baseline_needs = jobs["update-config-baseline"].get("needs")
        assert "preflight" in baseline_needs and "build" in baseline_needs
        assert "build_needed == 'true'" in jobs["update-config-baseline"].get("if", "")
        assert "build.result == 'success'" in jobs["update-config-baseline"].get("if", "")

    def test_build_matrix_coverage(self, build_workflow_yaml: dict):
        """Verify the build matrix defines all 4 required compilation legs."""
        matrix_includes = build_workflow_yaml["jobs"]["build"]["strategy"]["matrix"]["include"]
        assert len(matrix_includes) == 4, "Matrix must have exactly 4 legs (2 archs x 2 profiles)"

        legs = {(m["arch"], m["profile"]): m for m in matrix_includes}
        assert ("x86_64", "standard") in legs
        assert ("x86_64", "max") in legs
        assert ("arm64", "standard") in legs
        assert ("arm64", "max") in legs

        # Check runner types
        assert legs[("x86_64", "standard")]["runs_on"] == "ubuntu-latest"
        assert legs[("arm64", "standard")]["runs_on"] == "ubuntu-24.04-arm"
        assert legs[("x86_64", "max")]["runs_on"] == "ubuntu-latest"
        assert legs[("arm64", "max")]["runs_on"] == "ubuntu-24.04-arm"

        # Check localversion tags
        assert legs[("x86_64", "standard")]["localversion"] == "-bbrv3"
        assert legs[("x86_64", "max")]["localversion"] == "-bbrv3-max"
        assert legs[("arm64", "standard")]["localversion"] == "-bbrv3"
        assert legs[("arm64", "max")]["localversion"] == "-bbrv3-max"


# ==============================================================================
# 7. Kconfig Syntax & Format Integrity
# ==============================================================================

class TestKconfigSyntaxAndIntegrity:
    """Validate kernel configuration files syntax and integrity."""

    def test_no_syntax_errors_in_kconfigs(self, repo_root: Path):
        """Verify every non-comment line is well-formed KEY=VALUE."""
        valid_pattern = re.compile(r'^[A-Za-z0-9_]+=(?:[ymn]|".*"|-?[0-9]+|0x[0-9a-fA-F]+)$')
        comment_pattern = re.compile(r'^#(?:[ ].*)?$')

        for cfg_name in ["x86-64.config", "arm64.config"]:
            cfg_file = repo_root / cfg_name
            with open(cfg_file, "r", encoding="utf-8", errors="replace") as f:
                for line_no, raw_line in enumerate(f, 1):
                    line = raw_line.strip()
                    if not line:
                        continue
                    if line.startswith("#"):
                        assert comment_pattern.match(line), (
                            f"{cfg_name}:{line_no} malformed comment: {line}"
                        )
                    else:
                        assert valid_pattern.match(line), (
                            f"{cfg_name}:{line_no} malformed config line: {line}"
                        )
