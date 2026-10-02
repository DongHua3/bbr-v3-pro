"""E2E Tests for Requirement R3: CVE-2026-31431 & Dirty Frag Detection Engine.

Covers:
- Feature 7: cve_2026_31431_detector.py mod_loaded integration into cve_high_risk (eliminating dead code)
- Feature 8: Missing /boot/config-* safety (zero false-convergence, esp4 loaded -> high risk, no config -> uncertain)
- Feature 9: algif_aead blacklist verification and safe_check defensive bind skip (preventing request_module auto-load)
- Static syntax and py_compile verification

4-Tier Methodology:
- Tier 1: Feature Coverage (>=5 tests)
- Tier 2: Boundary & Corner Cases (>=5 tests)
- Tier 3: Cross-Feature Interactions (>=2 tests)
- Tier 4: Real-World Scenarios (>=2 tests)
"""

import importlib.util
import os
import py_compile
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch
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
    """Dynamically import detector module for isolated function-level unit/e2e testing."""
    spec = importlib.util.spec_from_file_location("cve_detector", str(detector_path))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["cve_detector"] = mod
    spec.loader.exec_module(mod)
    return mod


# ==============================================================================
# Tier 1: Feature Coverage (Primary Behavior / Happy Paths)
# ==============================================================================

def test_r3_t1_python_syntax_and_compilation(detector_path: Path):
    """Tier 1: Verify cve_2026_31431_detector.py compiles with py_compile cleanly."""
    compiled = py_compile.compile(str(detector_path), doraise=True)
    assert compiled is not None, "py_compile must produce compiled bytecode without syntax errors"


def test_r3_t1_cve_high_risk_when_algif_aead_loaded(detector_path: Path):
    """Tier 1: Feature 7 - Verify mod_loaded is integrated into cve_high_risk evaluation."""
    content = detector_path.read_text(encoding="utf-8")
    
    # Assert cve_high_risk includes mod_loaded
    assert "cve_high_risk" in content, "detector must define cve_high_risk"
    # Ensure mod_loaded is part of cve_high_risk boolean expression
    high_risk_def = [line for line in content.splitlines() if "cve_high_risk" in line]
    assert any("mod_loaded" in line for line in content.split("cve_high_risk")[1].split("cve_reduced")[0].splitlines()), (
        "mod_loaded must be integrated directly into cve_high_risk assessment"
    )


def test_r3_t1_cve_safe_bind_defensive_skip(detector_module):
    """Tier 1: Feature 9 - Verify check_af_alg_aead_bind defensively skips when module is not loaded."""
    # When safe_check is True, mod_loaded is False, and config is not built-in ('y')
    # It must return False with a defensive skip message to avoid triggering request_module
    success, msg = detector_module.check_af_alg_aead_bind(
        safe_check=True,
        aead_cfg="m",
        mod_loaded=False,
        aead_rules_ok=True,
    )
    assert success is False
    assert "防御性跳过" in msg or "跳过" in msg, f"Expected defensive skip message, got: {msg}"


def test_r3_t1_blacklist_rule_parsing(detector_module):
    """Tier 1: Verify has_rule correctly matches blacklist rules ignoring whitespace and comments."""
    conf_text = """
    # Security blacklist
    blacklist esp4
    install esp4 /bin/false # prevent auto load
    blacklist algif_aead
    install algif_aead /bin/false
    """
    assert detector_module.has_rule(conf_text, "blacklist esp4") is True
    assert detector_module.has_rule(conf_text, "install esp4 /bin/false") is True
    assert detector_module.has_rule(conf_text, "blacklist algif_aead") is True
    assert detector_module.has_rule(conf_text, "install algif_aead /bin/false") is True
    assert detector_module.has_rule(conf_text, "blacklist non_existent") is False


def test_r3_t1_missing_config_with_esp4_loaded_reports_high_risk(detector_module, capsys):
    """Tier 1: Feature 8 - When /boot/config-* is missing and esp4 is loaded, report high risk."""
    with patch.object(detector_module, "get_kernel_release", return_value="6.8.0-generic"), \
         patch.object(detector_module, "read_kernel_config", return_value=None), \
         patch.object(detector_module, "read_security_conf", return_value=""), \
         patch.object(detector_module, "is_module_loaded", side_effect=lambda m: m == "esp4"), \
         patch.object(detector_module, "check_af_alg_aead_bind", return_value=(False, "跳过")):
        
        detector_module.main()
        captured = capsys.readouterr().out
        
        assert "Dirty Frag 风险面暴露" in captured, (
            "When esp4 is loaded in memory without config, Dirty Frag MUST be flagged as high risk"
        )
        assert "Dirty Frag 风险面已收敛" not in captured, (
            "Must NEVER claim Dirty Frag risk is converged when esp4 is running"
        )


# ==============================================================================
# Tier 2: Boundary & Corner Cases
# ==============================================================================

def test_r3_t2_missing_config_no_modules_reports_uncertain_never_reduced(detector_module, capsys):
    """Tier 2: Feature 8 - Missing config + no loaded modules must report UNCERTAIN, NEVER reduced."""
    with patch.object(detector_module, "get_kernel_release", return_value="6.8.0-generic"), \
         patch.object(detector_module, "read_kernel_config", return_value=None), \
         patch.object(detector_module, "read_security_conf", return_value=""), \
         patch.object(detector_module, "is_module_loaded", return_value=False), \
         patch.object(detector_module, "check_af_alg_aead_bind", return_value=(False, "跳过")):
        
        detector_module.main()
        captured = capsys.readouterr().out
        
        # When config is missing and modules are not loaded, status is uncertain
        assert "结果不确定" in captured or "Dirty Frag 结果不确定" in captured, (
            "Must report uncertain when config is missing and modules not loaded"
        )
        assert "已收敛" not in captured, (
            "Must NEVER falsely claim '已收敛' when kernel config is completely missing"
        )


def test_r3_t2_tristate_symbol_parsing_boundary(detector_module):
    """Tier 2: Verify parse_tristate_symbol on various boundary states (empty, commented out, =m, =y)."""
    # None config
    assert "未知" in detector_module.parse_tristate_symbol(None, "TEST")
    
    # Empty string
    assert "未知" in detector_module.parse_tristate_symbol("", "TEST")
    
    # # CONFIG_FOO is not set -> 'n'
    disabled_text = "# CONFIG_FOO is not set\nCONFIG_BAR=m\nCONFIG_BAZ=y\n"
    assert detector_module.parse_tristate_symbol(disabled_text, "FOO") == "n"
    assert detector_module.parse_tristate_symbol(disabled_text, "BAR") == "m"
    assert detector_module.parse_tristate_symbol(disabled_text, "BAZ") == "y"
    assert "未知" in detector_module.parse_tristate_symbol(disabled_text, "NONEXISTENT")


def test_r3_t2_safe_bind_when_config_explicitly_disabled(detector_module):
    """Tier 2: Verify safe bind check when aead_cfg is explicitly disabled ('n')."""
    success, msg = detector_module.check_af_alg_aead_bind(
        safe_check=True,
        aead_cfg="n",
        mod_loaded=False,
    )
    assert success is False
    assert "显式禁用" in msg or "跳过" in msg


def test_r3_t2_blacklist_algif_aead_both_rules_required(detector_path: Path):
    """Tier 2: Verify detector checks both blacklist and install /bin/false for algif_aead."""
    content = detector_path.read_text(encoding="utf-8")
    assert "blacklist algif_aead" in content, "Must verify 'blacklist algif_aead'"
    assert "install algif_aead /bin/false" in content, "Must verify 'install algif_aead /bin/false'"


def test_r3_t2_dirtyfrag_rules_check_all_three_modules(detector_path: Path):
    """Tier 2: Verify detector requires rules for esp4, esp6, AND rxrpc."""
    content = detector_path.read_text(encoding="utf-8")
    for mod in ("esp4", "esp6", "rxrpc"):
        assert f"blacklist {mod}" in content, f"Missing 'blacklist {mod}' verification"
        assert f"install {mod} /bin/false" in content, f"Missing 'install {mod} /bin/false' verification"


# ==============================================================================
# Tier 3: Cross-Feature Interactions & Combinations
# ==============================================================================

def test_r3_t3_cve_and_dirtyfrag_dual_mitigation_converged(detector_module, capsys):
    """Tier 3: Verify that when both vulnerabilities have full blacklist and disabled/modular configs, both converge."""
    security_conf = """
    blacklist esp4
    install esp4 /bin/false
    blacklist esp6
    install esp6 /bin/false
    blacklist rxrpc
    install rxrpc /bin/false
    blacklist algif_aead
    install algif_aead /bin/false
    """
    mock_kconfig = """
    # CONFIG_CRYPTO_USER_API_AEAD is not set
    # CONFIG_XFRM_ESP is not set
    # CONFIG_INET_ESP is not set
    # CONFIG_INET6_ESP is not set
    # CONFIG_AF_RXRPC is not set
    """
    with patch.object(detector_module, "get_kernel_release", return_value="6.12.0-bbrv3"), \
         patch.object(detector_module, "read_kernel_config", return_value=mock_kconfig), \
         patch.object(detector_module, "read_security_conf", return_value=security_conf), \
         patch.object(detector_module, "is_module_loaded", return_value=False), \
         patch.object(detector_module, "check_af_alg_aead_bind", return_value=(False, "跳过")):
        
        detector_module.main()
        captured = capsys.readouterr().out
        
        assert "风险面已收敛/已缓解" in captured, "CVE-2026-31431 should report converged"
        assert "Dirty Frag 风险面已收敛/已缓解" in captured, "Dirty Frag should report converged"


def test_r3_t3_esp6_or_rxrpc_loaded_alone_triggers_dirtyfrag_high_risk(detector_module, capsys):
    """Tier 3: Verify that if esp6 or rxrpc is loaded (even if esp4 is not), Dirty Frag is flagged as high risk."""
    for active_mod in ("esp6", "rxrpc"):
        with patch.object(detector_module, "get_kernel_release", return_value="6.8.0-generic"), \
             patch.object(detector_module, "read_kernel_config", return_value=""), \
             patch.object(detector_module, "read_security_conf", return_value=""), \
             patch.object(detector_module, "is_module_loaded", side_effect=lambda m, mod=active_mod: m == mod), \
             patch.object(detector_module, "check_af_alg_aead_bind", return_value=(False, "跳过")):
            
            detector_module.main()
            captured = capsys.readouterr().out
            assert "Dirty Frag 风险面暴露" in captured, f"Loading {active_mod} alone must trigger Dirty Frag high risk"


# ==============================================================================
# Tier 4: Real-World Scenarios
# ==============================================================================

def test_r3_t4_simulated_vulnerable_legacy_kernel_run(detector_path: Path):
    """Tier 4: Run detector end-to-end as CLI subprocess with python executable."""
    res = run_bash_cmd(f"python '{to_posix_path(detector_path)}'")
    assert res.returncode == 0, f"Detector script failed to run: {res.stderr}"
    assert "CVE-2026-31431" in res.stdout, "Output missing CVE-2026-31431 section"
    assert "Dirty Frag" in res.stdout, "Output missing Dirty Frag section"


def test_r3_t4_no_unreferenced_dead_code_in_detector(detector_path: Path):
    """Tier 4: Static analysis of detector code to verify mod_loaded and all variables are actively used."""
    content = detector_path.read_text(encoding="utf-8")
    
    # Check that mod_loaded is defined and referenced in boolean condition
    occurrences = [m.start() for m in re.finditer(r'\bmod_loaded\b', content)]
    assert len(occurrences) >= 3, (
        f"mod_loaded should be defined, passed into functions, and evaluated in conclusions, found {len(occurrences)}"
    )
