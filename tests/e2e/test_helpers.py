"""Shared test utilities and fixtures for bbr-v3-pro E2E test suite.
Supports cross-platform execution (Windows, Linux, macOS) with automatic
bash discovery, mock sandboxing, and configuration parsing.
"""

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional
import yaml


def get_repo_root() -> Path:
    """Return the absolute Path to the repository root directory."""
    # tests/e2e/test_helpers.py -> repo_root is parent.parent.parent
    return Path(__file__).resolve().parent.parent.parent


def get_bash_path() -> str:
    """Find bash executable in PATH or standard Git directories."""
    path = shutil.which("bash")
    if path:
        return path
    git_path = shutil.which("git")
    if git_path:
        git_dir = Path(git_path).resolve().parent.parent
        for candidate in [
            git_dir / "bin" / "bash.exe",
            git_dir / "usr" / "bin" / "bash.exe",
        ]:
            if candidate.exists():
                return str(candidate)
    for default_cand in [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"D:\Git\bin\bash.exe",
        r"D:\Git\usr\bin\bash.exe",
    ]:
        if Path(default_cand).exists():
            return default_cand
    return "bash"


def to_posix_path(p: Path | str) -> str:
    """Convert path to forward-slash format compatible with bash on Windows/Linux."""
    return str(p).replace("\\", "/")


def run_bash_cmd(
    cmd: str,
    cwd: Optional[Path | str] = None,
    env: Optional[Dict[str, str]] = None,
    timeout: int = 30,
) -> subprocess.CompletedProcess:
    """Execute a bash command string using the discovered bash executable."""
    bash = get_bash_path()
    work_dir = cwd or get_repo_root()
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [bash, "-c", cmd],
        cwd=str(work_dir),
        env=merged_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )


def run_bash_script(
    script_path: Path | str,
    args: Optional[List[str]] = None,
    cwd: Optional[Path | str] = None,
    env: Optional[Dict[str, str]] = None,
    timeout: int = 30,
) -> subprocess.CompletedProcess:
    """Execute a bash script file."""
    bash = get_bash_path()
    work_dir = cwd or get_repo_root()
    posix_script = to_posix_path(script_path)
    cmd_args = [bash, posix_script] + (args or [])
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        cmd_args,
        cwd=str(work_dir),
        env=merged_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )


def load_yaml_file(path: Path | str) -> Dict[str, Any]:
    """Parse a YAML file into Python dict."""
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def parse_kconfig_file(path: Path | str) -> Dict[str, str]:
    """Parse kernel configuration file into symbol -> value dictionary.
    
    Examples:
    CONFIG_HYPERV=m -> {"CONFIG_HYPERV": "m"}
    # CONFIG_XFRM_ESP is not set -> {"CONFIG_XFRM_ESP": "n"}
    CONFIG_DEFAULT_TCP_CONG="bbr" -> {"CONFIG_DEFAULT_TCP_CONG": '"bbr"'}
    """
    configs: Dict[str, str] = {}
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("# CONFIG_") and line.endswith(" is not set"):
                sym = line[2:].split()[0]
                configs[sym] = "n"
            elif line.startswith("CONFIG_") and "=" in line:
                k, v = line.split("=", 1)
                configs[k.strip()] = v.strip()
    return configs
