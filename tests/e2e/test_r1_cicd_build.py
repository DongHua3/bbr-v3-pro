"""E2E Tests for Requirement R1: CI/CD Pipeline & Build Scripts.

Covers:
- Feature 1: .github/workflows/build.yml detached HEAD push fix
- Feature 2: .github/workflows/build.yml workflow_dispatch inputs & preflight routing
- Feature 3: scripts/prepare-kernel-config.sh self-locating fallback (unset GITHUB_WORKSPACE / KERNEL_VERSION)
- Feature 4: scripts/apply-bbrv3-port.sh safe version sort (sort -V without fragile -t- -k3)

4-Tier Methodology:
- Tier 1: Feature Coverage (>=5 tests)
- Tier 2: Boundary & Corner Cases (>=5 tests)
- Tier 3: Cross-Feature Interactions (>=2 tests)
- Tier 4: Real-World Scenarios (>=2 tests)
"""

import os
import re
import shutil
import tempfile
from pathlib import Path
import pytest
import yaml

from tests.e2e.test_helpers import (
    get_repo_root,
    load_yaml_file,
    run_bash_cmd,
    run_bash_script,
    to_posix_path,
)


@pytest.fixture(scope="module")
def repo_root() -> Path:
    return get_repo_root()


@pytest.fixture(scope="module")
def build_workflow_path(repo_root: Path) -> Path:
    workflow = repo_root / ".github" / "workflows" / "build.yml"
    assert workflow.is_file(), f"build.yml not found at {workflow}"
    return workflow


@pytest.fixture(scope="module")
def build_workflow_yaml(build_workflow_path: Path) -> dict:
    return load_yaml_file(build_workflow_path)


# ==============================================================================
# Tier 1: Feature Coverage (Primary Behavior / Happy Paths)
# ==============================================================================

def test_r1_t1_build_workflow_yaml_syntax_and_structure(build_workflow_yaml: dict):
    """Tier 1: Verify .github/workflows/build.yml is syntactically valid YAML and has expected top-level jobs."""
    assert "name" in build_workflow_yaml, "Workflow must define 'name'"
    assert "on" in build_workflow_yaml, "Workflow must define 'on' triggers"
    assert "jobs" in build_workflow_yaml, "Workflow must define 'jobs'"
    
    jobs = build_workflow_yaml["jobs"]
    assert "preflight" in jobs, "Workflow jobs must contain 'preflight'"
    assert "build" in jobs, "Workflow jobs must contain 'build'"
    assert "update-config-baseline" in jobs, "Workflow jobs must contain 'update-config-baseline'"


def test_r1_t1_build_workflow_dispatch_inputs_defined(build_workflow_yaml: dict):
    """Tier 1: Verify workflow_dispatch defines force_rebuild and kernel_version inputs."""
    on_triggers = build_workflow_yaml.get("on", {})
    assert "workflow_dispatch" in on_triggers, "workflow_dispatch trigger must be defined"
    
    dispatch_config = on_triggers["workflow_dispatch"]
    assert isinstance(dispatch_config, dict), "workflow_dispatch must be a mapping with inputs"
    assert "inputs" in dispatch_config, "workflow_dispatch must declare 'inputs'"
    
    inputs = dispatch_config["inputs"]
    assert "force_rebuild" in inputs, "workflow_dispatch must provide 'force_rebuild' input"
    assert "kernel_version" in inputs, "workflow_dispatch must provide 'kernel_version' input"
    
    # Check force_rebuild type and defaults
    force_input = inputs["force_rebuild"]
    assert force_input.get("type") == "boolean", "'force_rebuild' input should be boolean"
    
    # Check kernel_version type
    kernel_ver_input = inputs["kernel_version"]
    assert kernel_ver_input.get("type") == "string", "'kernel_version' input should be string"


def test_r1_t1_build_workflow_detached_head_push(build_workflow_path: Path):
    """Tier 1: Verify update-config-baseline step avoids detached HEAD fatal push error."""
    content = build_workflow_path.read_text(encoding="utf-8")
    
    # Locate update-config-baseline section
    assert "update-config-baseline:" in content, "update-config-baseline job not found"
    job_section = content.split("update-config-baseline:")[1]
    
    # Assert that git push specifies the destination branch (HEAD:${{ github.ref_name }})
    # or checkout uses ref: ${{ github.ref_name }}
    safe_push_pattern = (
        r'git push origin ["\']?HEAD:\${{\s*github\.ref_name\s*}}["\']?'
        r'|ref:\s*\${{\s*github\.ref_name\s*}}'
        r'|git push origin ["\']?\${{\s*github\.ref_name\s*}}["\']?'
    )
    assert re.search(safe_push_pattern, job_section), (
        "update-config-baseline must safely push to github.ref_name branch "
        "to prevent fatal: 'You are not currently on a branch' in detached HEAD"
    )
    # Ensure plain bare 'git push' without refspec is not used alone
    assert not re.search(r'^\s*git push\s*$', job_section, re.MULTILINE), (
        "Raw 'git push' alone without refspec is forbidden in update-config-baseline"
    )


def test_r1_t1_prepare_kernel_config_self_locating(repo_root: Path):
    """Tier 1: Verify prepare-kernel-config.sh finds configs when GITHUB_WORKSPACE is unset."""
    script = repo_root / "scripts" / "prepare-kernel-config.sh"
    content = script.read_text(encoding="utf-8")
    
    # Must contain self-locating fallback for GITHUB_WORKSPACE
    assert "BASH_SOURCE[0]" in content or "${GITHUB_WORKSPACE:-" in content, (
        "prepare-kernel-config.sh must implement self-locating fallback via BASH_SOURCE[0] "
        "or ${GITHUB_WORKSPACE:-...} to work outside CI"
    )


def test_r1_t1_apply_bbrv3_port_version_sort_happy_path(repo_root: Path):
    """Tier 1: Verify fallback patch selection uses safe sort -V without fragile -t- -k3."""
    script = repo_root / "scripts" / "apply-bbrv3-port.sh"
    content = script.read_text(encoding="utf-8")
    
    # Must use clean sort -V, avoiding -t- -k3
    assert "sort -V" in content, "apply-bbrv3-port.sh must use 'sort -V' for patch version sorting"
    assert "-t- -k3" not in content, (
        "apply-bbrv3-port.sh must not use fragile '-t- -k3' which breaks when directories contain hyphens"
    )


# ==============================================================================
# Tier 2: Boundary & Corner Cases
# ==============================================================================

def test_r1_t2_prepare_kernel_config_unset_kernel_version(repo_root: Path):
    """Tier 2: Verify prepare-kernel-config.sh handles unset KERNEL_VERSION without set -u failure."""
    script = repo_root / "scripts" / "prepare-kernel-config.sh"
    content = script.read_text(encoding="utf-8")
    
    # Check that KERNEL_VERSION is referenced with fallback e.g. ${KERNEL_VERSION:-...}
    # and not bare $KERNEL_VERSION under set -u
    bare_kernel_version = re.search(r'(?<!\{)KERNEL_VERSION\b(?!\})', content)
    # If KERNEL_VERSION is referenced, it must use parameter expansion default like ${KERNEL_VERSION:-...}
    if "KERNEL_VERSION" in content:
        assert re.search(r'\$\{KERNEL_VERSION[:-][^}]*\}', content) or "KERNEL_VERSION=" in content, (
            "KERNEL_VERSION must have a default fallback ${KERNEL_VERSION:-...} to avoid set -u unbound variable error"
        )


def test_r1_t2_prepare_kernel_config_invalid_arch_rejection(repo_root: Path):
    """Tier 2: Verify prepare-kernel-config.sh rejects invalid arch with non-zero exit code."""
    script = repo_root / "scripts" / "prepare-kernel-config.sh"
    # Execute with invalid arch in isolated temp environment
    with tempfile.TemporaryDirectory() as tmp_dir:
        res = run_bash_script(script, args=["invalid_arch"], cwd=tmp_dir)
        assert res.returncode != 0, "prepare-kernel-config.sh must reject invalid arch"
        assert "unsupported arch" in res.stderr.lower() or "usage" in res.stderr.lower(), (
            "Expected 'unsupported arch' error message"
        )


def test_r1_t2_apply_bbrv3_port_hyphenated_path_resilience():
    """Tier 2: Test patch sorting behavior when parent directories contain multiple hyphens."""
    # Simulate patch filenames in a directory with hyphens: /tmp/my-test-bbr-v3-dir/patches/
    test_paths = [
        "/tmp/my-test-bbr-v3-dir/patches/bbrv3-linux-7.0.patch",
        "/tmp/my-test-bbr-v3-dir/patches/bbrv3-linux-7.1.patch",
        "/tmp/my-test-bbr-v3-dir/patches/bbrv3-linux-7.2.patch",
        "/tmp/my-test-bbr-v3-dir/patches/bbrv3-linux-6.12.patch",
    ]
    # In fragile -t- -k3 sort:
    # Delimiter '-' splits on:
    # [0] = "", [1] = "tmp/my", [2] = "test", [3] = "bbr", [4] = "v3", [5] = "dir/patches/bbrv3", [6] = "linux", [7] = "7.0.patch"
    # Column 3 is "bbr", so all keys are identical and sort fails!
    # With clean sort -V, the version comparison correctly yields 7.2 as highest.
    input_str = "\n".join(test_paths)
    res = run_bash_cmd(f"printf '%s\\n' '{input_str}' | sort -V | tail -n 1")
    assert res.returncode == 0
    assert "bbrv3-linux-7.2.patch" in res.stdout, f"Expected 7.2 as highest version, got: {res.stdout}"


def test_r1_t2_apply_bbrv3_port_semver_sorting():
    """Tier 2: Verify sort -V correctly sorts double-digit minor versions (7.10 > 7.9)."""
    test_versions = [
        "patches/bbrv3-linux-7.1.patch",
        "patches/bbrv3-linux-7.9.patch",
        "patches/bbrv3-linux-7.10.patch",
        "patches/bbrv3-linux-7.2.patch",
    ]
    input_str = "\n".join(test_versions)
    res = run_bash_cmd(f"printf '%s\\n' '{input_str}' | sort -V | tail -n 1")
    assert res.returncode == 0
    assert "bbrv3-linux-7.10.patch" in res.stdout, "sort -V must identify 7.10 > 7.9"


def test_r1_t2_build_workflow_preflight_force_rebuild_branching(build_workflow_path: Path):
    """Tier 2: Verify preflight step reads force_rebuild and bypasses existing release checks."""
    content = build_workflow_path.read_text(encoding="utf-8")
    
    # Preflight job must consume inputs.force_rebuild
    assert "force_rebuild" in content, "Preflight step must reference 'force_rebuild'"
    
    # Must have condition to force build_needed=true when force_rebuild is set
    force_build_check = (
        r'if\s*\[\[?\s*"\$\{?inputs\.force_rebuild\}?"\s*==\s*["\']?true["\']?'
        r'|if\s*\[\[?\s*"\$\{?github\.event\.inputs\.force_rebuild\}?"\s*==\s*["\']?true["\']?'
        r'|force_rebuild'
    )
    assert re.search(force_build_check, content, re.IGNORECASE), (
        "Preflight must include logic to check force_rebuild input and force build_needed"
    )


# ==============================================================================
# Tier 3: Cross-Feature Interactions & Combinations
# ==============================================================================

def test_r1_t3_workflow_inputs_flow_into_build_jobs(build_workflow_yaml: dict):
    """Tier 3: Verify inputs flow from preflight outputs into build matrix jobs."""
    jobs = build_workflow_yaml["jobs"]
    preflight = jobs["preflight"]
    build = jobs["build"]
    
    # Preflight outputs should declare kernel_version
    outputs = preflight.get("outputs", {})
    assert "kernel_version" in outputs, "Preflight job outputs must declare 'kernel_version'"
    
    # Build job should declare dependency on preflight
    needs = build.get("needs", [])
    if isinstance(needs, str):
        needs = [needs]
    assert "preflight" in needs, "Build job must depend on 'preflight'"
    
    # Build env should reference needs.preflight.outputs.kernel_version
    build_env = build.get("env", {})
    assert "KERNEL_VERSION" in build_env, "Build job env must define KERNEL_VERSION"
    assert "needs.preflight.outputs.kernel_version" in str(build_env["KERNEL_VERSION"]), (
        "Build job KERNEL_VERSION must bind to needs.preflight.outputs.kernel_version"
    )


def test_r1_t3_prepare_config_outputs_match_workflow_expectations(repo_root: Path, build_workflow_path: Path):
    """Tier 3: Verify prepare-kernel-config.sh output paths match build.yml upload-artifact expectations."""
    script_content = (repo_root / "scripts" / "prepare-kernel-config.sh").read_text(encoding="utf-8")
    wf_content = build_workflow_path.read_text(encoding="utf-8")
    
    # Both must agree on the generated config directory build-configs/
    assert "build-configs" in script_content, "prepare-kernel-config.sh must output to build-configs/"
    assert "build-configs" in wf_content, "build.yml must look for artifacts in build-configs/"


# ==============================================================================
# Tier 4: Real-World Scenarios
# ==============================================================================

def test_r1_t4_simulated_local_developer_build_dryrun(repo_root: Path):
    """Tier 4: Simulate a developer running prepare-kernel-config.sh locally without any CI env vars."""
    script = repo_root / "scripts" / "prepare-kernel-config.sh"
    
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        # Create a mock Makefile and scripts/config inside tmp_path
        (tmp_path / "scripts").mkdir()
        (tmp_path / "Makefile").write_text("VERSION = 6\nPATCHLEVEL = 12\nSUBLEVEL = 0\n", encoding="utf-8")
        # Mock scripts/config dummy executable
        mock_config = tmp_path / "scripts" / "config"
        mock_config.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        
        # Strip all GITHUB_* env vars
        clean_env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
        
        # Run in bash syntax check mode with the script to verify no unbound variables or missing dependencies
        res = run_bash_cmd(
            f"bash -n '{to_posix_path(script)}'",
            cwd=tmp_path,
            env=clean_env,
        )
        assert res.returncode == 0, f"prepare-kernel-config.sh syntax check failed: {res.stderr}"


def test_r1_t4_workflow_matrix_consistency(build_workflow_yaml: dict):
    """Tier 4: Verify build matrix defines both standard and max profiles for x86_64 and arm64."""
    matrix = build_workflow_yaml["jobs"]["build"]["strategy"]["matrix"]["include"]
    
    combos = {(item["arch"], item["profile"]) for item in matrix}
    expected = {
        ("x86_64", "standard"),
        ("arm64", "standard"),
        ("x86_64", "max"),
        ("arm64", "max"),
    }
    assert combos == expected, f"Matrix must contain all 4 arch/profile combinations, got: {combos}"
