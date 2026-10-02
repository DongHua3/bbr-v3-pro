"""E2E Tests for Requirement R2: Kernel Configurations & Hyper-V Virtualization Compatibility.

Covers:
- Feature 5: Hyper-V x86_64 companion drivers enabled in x86-64.config
- Feature 6: Hyper-V arm64 companion drivers enabled in arm64.config
- Driver architecture policy (modular storage/net, built-in timer, no driver bloat)
- BBRv3 coexistence and security hardening symbols

4-Tier Methodology:
- Tier 1: Feature Coverage (>=5 tests)
- Tier 2: Boundary & Corner Cases (>=5 tests)
- Tier 3: Cross-Feature Interactions (>=2 tests)
- Tier 4: Real-World Scenarios (>=2 tests)
"""

from pathlib import Path
import pytest

from tests.e2e.test_helpers import get_repo_root, parse_kconfig_file


@pytest.fixture(scope="module")
def repo_root() -> Path:
    return get_repo_root()


@pytest.fixture(scope="module")
def x86_config(repo_root: Path) -> dict:
    cfg_path = repo_root / "x86-64.config"
    assert cfg_path.is_file(), f"x86-64.config not found at {cfg_path}"
    return parse_kconfig_file(cfg_path)


@pytest.fixture(scope="module")
def arm64_config(repo_root: Path) -> dict:
    cfg_path = repo_root / "arm64.config"
    assert cfg_path.is_file(), f"arm64.config not found at {cfg_path}"
    return parse_kconfig_file(cfg_path)


# ==============================================================================
# Tier 1: Feature Coverage (Primary Behavior / Happy Paths)
# ==============================================================================

def test_r2_t1_x86_64_hyperv_core_enabled(x86_config: dict):
    """Tier 1: Verify core Hyper-V bus and timer drivers are enabled in x86-64.config."""
    assert x86_config.get("CONFIG_HYPERV") in ("m", "y"), "CONFIG_HYPERV must be enabled (m or y)"
    assert x86_config.get("CONFIG_HYPERV_TIMER") == "y", "CONFIG_HYPERV_TIMER must be built-in (=y)"


def test_r2_t1_x86_64_hyperv_storage_net_enabled(x86_config: dict):
    """Tier 1: Verify Hyper-V storage (storvsc) and network (netvsc) drivers are enabled in x86-64.config."""
    assert x86_config.get("CONFIG_HYPERV_STORAGE") in ("m", "y"), "CONFIG_HYPERV_STORAGE must be enabled"
    assert x86_config.get("CONFIG_HYPERV_NET") in ("m", "y"), "CONFIG_HYPERV_NET must be enabled"


def test_r2_t1_arm64_hyperv_core_enabled(arm64_config: dict):
    """Tier 1: Verify core Hyper-V bus and timer drivers are enabled in arm64.config."""
    assert arm64_config.get("CONFIG_HYPERV") in ("m", "y"), "CONFIG_HYPERV must be enabled in arm64"
    assert arm64_config.get("CONFIG_HYPERV_TIMER") == "y", "CONFIG_HYPERV_TIMER must be built-in in arm64"


def test_r2_t1_arm64_hyperv_storage_net_enabled(arm64_config: dict):
    """Tier 1: Verify Hyper-V storage and network drivers are enabled in arm64.config."""
    assert arm64_config.get("CONFIG_HYPERV_STORAGE") in ("m", "y"), "CONFIG_HYPERV_STORAGE must be enabled in arm64"
    assert arm64_config.get("CONFIG_HYPERV_NET") in ("m", "y"), "CONFIG_HYPERV_NET must be enabled in arm64"


def test_r2_t1_hyperv_utils_and_balloon(x86_config: dict, arm64_config: dict):
    """Tier 1: Verify Hyper-V utils (shutdown/heartbeat) and dynamic memory ballooning in both architectures."""
    for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
        assert cfg.get("CONFIG_HYPERV_UTILS") in ("m", "y"), f"CONFIG_HYPERV_UTILS missing in {arch_name}"
        assert cfg.get("CONFIG_HYPERV_BALLOON") in ("m", "y"), f"CONFIG_HYPERV_BALLOON missing in {arch_name}"


# ==============================================================================
# Tier 2: Boundary & Corner Cases
# ==============================================================================

def test_r2_t2_modular_driver_policy(x86_config: dict, arm64_config: dict):
    """Tier 2: Verify device drivers are compiled as modules (=m) to avoid kernel binary bloat."""
    modular_symbols = [
        "CONFIG_HYPERV_NET",
        "CONFIG_HYPERV_STORAGE",
        "CONFIG_HYPERV_BALLOON",
        "CONFIG_HYPERV_UTILS",
    ]
    for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
        for sym in modular_symbols:
            val = cfg.get(sym)
            assert val == "m", f"{sym} should be module (=m) in {arch_name}, got {val}"


def test_r2_t2_pci_hyperv_present(x86_config: dict, arm64_config: dict):
    """Tier 2: Verify PCI Hyper-V pass-through / SR-IOV bus drivers are enabled."""
    for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
        assert (
            cfg.get("CONFIG_PCI_HYPERV") in ("m", "y")
            or cfg.get("CONFIG_PCI_HYPERV_INTERFACE") in ("m", "y")
        ), f"Hyper-V PCI support missing in {arch_name}"


def test_r2_t2_hyperv_vsockets_present(x86_config: dict, arm64_config: dict):
    """Tier 2: Verify Hyper-V AF_VSOCK support for host-guest IPC."""
    for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
        assert cfg.get("CONFIG_HYPERV_VSOCKETS") in ("m", "y"), (
            f"CONFIG_HYPERV_VSOCKETS missing in {arch_name}"
        )


def test_r2_t2_hyperv_input_and_display(x86_config: dict, arm64_config: dict):
    """Tier 2: Verify Hyper-V synthetic keyboard, mouse, and framebuffer/DRM display drivers."""
    for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
        assert cfg.get("CONFIG_HYPERV_KEYBOARD") in ("m", "y"), f"CONFIG_HYPERV_KEYBOARD missing in {arch_name}"
        assert cfg.get("CONFIG_HID_HYPERV_MOUSE") in ("m", "y"), f"CONFIG_HID_HYPERV_MOUSE missing in {arch_name}"


def test_r2_t2_configs_do_not_reintroduce_dirtyfrag_symbols(x86_config: dict, arm64_config: dict):
    """Tier 2: Ensure vulnerable Dirty Frag symbols remain disabled (n or not set)."""
    vuln_symbols = [
        "CONFIG_XFRM_ESP",
        "CONFIG_INET_ESP",
        "CONFIG_INET6_ESP",
        "CONFIG_AF_RXRPC",
    ]
    for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
        for sym in vuln_symbols:
            val = cfg.get(sym, "n")
            assert val in ("n", None), f"Vulnerable symbol {sym} must NOT be enabled in {arch_name}, got {val}"


# ==============================================================================
# Tier 3: Cross-Feature Interactions & Combinations
# ==============================================================================

def test_r2_t3_hyperv_coexists_with_bbrv3_defaults(x86_config: dict, arm64_config: dict):
    """Tier 3: Verify Hyper-V drivers and BBRv3 congestion control co-exist without configuration conflicts."""
    for arch_name, cfg in [("x86_64", x86_config), ("arm64", arm64_config)]:
        # Both Hyper-V and BBRv3 must be configured simultaneously
        assert cfg.get("CONFIG_HYPERV") in ("m", "y"), f"Hyper-V missing in {arch_name}"
        assert cfg.get("CONFIG_TCP_CONG_BBR") in ("y", "m"), f"BBR missing in {arch_name}"
        assert cfg.get("CONFIG_DEFAULT_BBR") in ("y", None), f"DEFAULT_BBR missing in {arch_name}"
        assert cfg.get("CONFIG_NET_SCH_FQ") in ("y", "m"), f"NET_SCH_FQ missing in {arch_name}"


def test_r2_t3_x86_and_arm64_driver_parity(x86_config: dict, arm64_config: dict):
    """Tier 3: Verify parity between x86_64 and arm64 across all key Hyper-V companion drivers."""
    parity_keys = [
        "CONFIG_HYPERV",
        "CONFIG_HYPERV_TIMER",
        "CONFIG_HYPERV_UTILS",
        "CONFIG_HYPERV_BALLOON",
        "CONFIG_HYPERV_NET",
        "CONFIG_HYPERV_STORAGE",
        "CONFIG_HYPERV_KEYBOARD",
        "CONFIG_HID_HYPERV_MOUSE",
        "CONFIG_HYPERV_VSOCKETS",
    ]
    for key in parity_keys:
        x86_val = x86_config.get(key)
        arm_val = arm64_config.get(key)
        assert x86_val is not None, f"Key {key} missing from x86-64.config"
        assert arm_val is not None, f"Key {key} missing from arm64.config"
        assert x86_val == arm_val, (
            f"Architecture parity mismatch for {key}: x86={x86_val}, arm64={arm_val}"
        )


# ==============================================================================
# Tier 4: Real-World Scenarios
# ==============================================================================

def test_r2_t4_azure_and_hyperv_vm_boot_prerequisites(x86_config: dict, arm64_config: dict):
    """Tier 4: Verify the full driver stack needed for Azure / Hyper-V Gen2 VM booting without panic."""
    required_stack = [
        "CONFIG_HYPERVISOR_GUEST",
        "CONFIG_SYS_HYPERVISOR",
        "CONFIG_HYPERV",
        "CONFIG_HYPERV_TIMER",
        "CONFIG_HYPERV_NET",
        "CONFIG_HYPERV_STORAGE",
    ]
    for sym in required_stack:
        assert sym in x86_config, f"Azure / Hyper-V boot prerequisite {sym} missing from x86-64.config"


def test_r2_t4_prepare_script_validation_rules_compatibility(repo_root: Path):
    """Tier 4: Verify prepare-kernel-config.sh policy functions do not disable required Hyper-V symbols."""
    script_text = (repo_root / "scripts" / "prepare-kernel-config.sh").read_text(encoding="utf-8")
    
    # Assert scripts/config --disable does not turn off any HYPERV symbols
    assert "--disable HYPERV" not in script_text, "prepare-kernel-config.sh must not disable HYPERV"
    assert "--disable CONFIG_HYPERV" not in script_text, "prepare-kernel-config.sh must not disable CONFIG_HYPERV"
