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


_CACHED_BASH_PATH: Optional[str] = None


def _is_usable_bash(candidate: str) -> bool:
    """Return True if candidate bash executable can run a trivial command."""
    norm = candidate.replace("/", "\\").lower()
    if os.name == "nt" and ("\\windowsapps\\bash.exe" in norm or "\\system32\\bash.exe" in norm):
        try:
            res = subprocess.run(
                [candidate, "-c", "exit 0"],
                capture_output=True,
                timeout=3,
            )
            return res.returncode == 0
        except OSError:
            return False
    return Path(candidate).is_file()


def get_bash_path() -> str:
    """Find a working bash executable in PATH or standard Git directories."""
    global _CACHED_BASH_PATH
    if _CACHED_BASH_PATH:
        return _CACHED_BASH_PATH

    candidates: List[str] = []
    if os.name == "nt":
        git_path = shutil.which("git")
        if git_path:
            git_dir = Path(git_path).resolve().parent.parent
            for cand in [
                git_dir / "bin" / "bash.exe",
                git_dir / "usr" / "bin" / "bash.exe",
            ]:
                if cand.exists():
                    candidates.append(str(cand))
        for default_cand in [
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files\Git\usr\bin\bash.exe",
            r"D:\Git\bin\bash.exe",
            r"D:\Git\usr\bin\bash.exe",
        ]:
            if Path(default_cand).exists():
                candidates.append(default_cand)

    which_bash = shutil.which("bash")
    if which_bash:
        candidates.append(which_bash)

    for cand in candidates:
        if _is_usable_bash(cand):
            _CACHED_BASH_PATH = cand
            return cand

    _CACHED_BASH_PATH = which_bash or "bash"
    return _CACHED_BASH_PATH


def _prepare_bash_env(bash_path: str, env: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """Ensure GNU coreutils from Git usr/bin precede Windows System32 utilities on Windows,
    while preserving any caller-prepended mock PATH directories first.
    """
    orig_sys_path = os.environ.get("PATH", "")
    merged_env = os.environ.copy()
    if os.name == "nt":
        bp = Path(bash_path).resolve()
        git_root = bp.parent.parent
        usr_bin = git_root / "usr" / "bin"
        bin_dir = git_root / "bin"
        extra_dirs = [str(d) for d in (bin_dir, usr_bin) if d.is_dir()]
        if extra_dirs:
            git_prefix = ";".join(extra_dirs)
            augmented_sys_path = f"{git_prefix};{orig_sys_path}" if orig_sys_path else git_prefix
            merged_env["PATH"] = augmented_sys_path
            if env:
                merged_env.update(env)
                if "PATH" in env:
                    caller_path = env["PATH"]
                    if orig_sys_path and orig_sys_path in caller_path:
                        merged_env["PATH"] = caller_path.replace(orig_sys_path, augmented_sys_path, 1)
                    else:
                        sep = ";" if ";" in caller_path else ":"
                        p_str = sep.join(to_posix_path(d) if sep == ":" else d for d in extra_dirs)
                        merged_env["PATH"] = f"{caller_path}{sep}{p_str}"
            return merged_env

    if env:
        merged_env.update(env)
    return merged_env


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
    merged_env = _prepare_bash_env(bash, env)
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
    merged_env = _prepare_bash_env(bash, env)
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
