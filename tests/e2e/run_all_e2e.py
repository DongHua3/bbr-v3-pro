#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Master E2E Test Suite Runner for bbr-v3-pro.

Executes all opaque-box requirements-driven tests across:
- R1: CI/CD Pipeline & Build Scripts (test_r1_cicd_build.py)
- R2: Kernel Configurations & Hyper-V Support (test_r2_hyperv_config.py)
- R3: CVE-2026-31431 & Dirty Frag Detection Engine (test_r3_cve_detector.py)
- R4: install.sh Management Script & Network Tuning (test_r4_install_script.py)

Organizes execution and reports along the 4-Tier Methodology:
- Tier 1: Feature Coverage (Primary Behavior / Happy Paths)
- Tier 2: Boundary & Corner Cases
- Tier 3: Cross-Feature Interactions & Combinations
- Tier 4: Real-World Scenarios & Workflows
"""

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional
import pytest


repo_root = Path(__file__).resolve().parent.parent.parent
if str(repo_root) not in sys.path:
    sys.path.insert(0, str(repo_root))


def get_test_dir() -> Path:
    return Path(__file__).resolve().parent


class E2ECollectorPlugin:
    """Pytest plugin to capture structured test results by requirement and tier."""

    def __init__(self):
        self.results = []

    def pytest_runtest_logreport(self, report):
        if report.when == "call":
            # Extract requirement (R1, R2, R3, R4) and Tier (T1, T2, T3, T4) from test name
            test_name = report.nodeid.split("::")[-1]
            file_name = report.nodeid.split("::")[0].split("/")[-1].split("\\")[-1]
            
            req = "Unknown"
            if "r1" in file_name or "r1" in test_name:
                req = "R1 (CI/CD & Build)"
            elif "r2" in file_name or "r2" in test_name:
                req = "R2 (Hyper-V Config)"
            elif "r3" in file_name or "r3" in test_name:
                req = "R3 (CVE Detector)"
            elif "r4" in file_name or "r4" in test_name:
                req = "R4 (Install Script)"

            tier = "Tier 1"
            if "_t1_" in test_name:
                tier = "Tier 1 (Feature Coverage)"
            elif "_t2_" in test_name:
                tier = "Tier 2 (Boundary & Corner)"
            elif "_t3_" in test_name:
                tier = "Tier 3 (Cross-Feature)"
            elif "_t4_" in test_name:
                tier = "Tier 4 (Real-World)"

            status = "PASSED" if report.passed else ("SKIPPED" if report.skipped else "FAILED")
            duration = report.duration
            failure_msg = ""
            if report.failed and report.longrepr:
                failure_msg = str(report.longrepr)

            self.results.append({
                "nodeid": report.nodeid,
                "name": test_name,
                "file": file_name,
                "requirement": req,
                "tier": tier,
                "status": status,
                "duration": duration,
                "failure": failure_msg,
            })


def print_matrix(results: List[Dict]):
    """Print ASCII summary matrix grouped by Requirement and Tier."""
    requirements = [
        "R1 (CI/CD & Build)",
        "R2 (Hyper-V Config)",
        "R3 (CVE Detector)",
        "R4 (Install Script)",
    ]
    tiers = [
        "Tier 1 (Feature Coverage)",
        "Tier 2 (Boundary & Corner)",
        "Tier 3 (Cross-Feature)",
        "Tier 4 (Real-World)",
    ]

    header = f"{'Requirement':<24} | " + " | ".join(f"{t.split()[0]+' '+t.split()[1]:<14}" for t in tiers) + " | Total"
    divider = "-" * len(header)
    print("\n" + "=" * len(header))
    print("                     E2E TEST SUITE EXECUTION MATRIX")
    print("=" * len(header))
    print(header)
    print(divider)

    total_passed = 0
    total_failed = 0
    total_tests = 0

    for req in requirements:
        row_str = f"{req:<24} | "
        req_passed = 0
        req_total = 0
        for tier in tiers:
            matches = [r for r in results if r["requirement"] == req and r["tier"] == tier]
            p = sum(1 for r in matches if r["status"] == "PASSED")
            t = len(matches)
            req_passed += p
            req_total += t
            if t == 0:
                cell = "N/A"
            else:
                cell = f"{p}/{t} passed"
            row_str += f"{cell:<14} | "
        row_str += f"{req_passed}/{req_total}"
        print(row_str)
        total_passed += req_passed
        total_tests += req_total

    total_failed = total_tests - total_passed
    print(divider)
    print(f"{'OVERALL TOTALS':<24} | {'':<14} | {'':<14} | {'':<14} | {'':<14} | {total_passed}/{total_tests} passed")
    print("=" * len(header) + "\n")


def print_failure_details(results: List[Dict]):
    """Print detailed escalation messages for failing tests."""
    failures = [r for r in results if r["status"] == "FAILED"]
    if not failures:
        print("[+] 100% of tested requirements passed cleanly!")
        return

    print("\n" + "!" * 80)
    print(f"[-] DEFECT ESCALATION REPORT: {len(failures)} test(s) failed.")
    print("!" * 80)

    for i, f in enumerate(failures, 1):
        print(f"\n[{i}] {f['requirement']} - {f['tier']}")
        print(f"    Test: {f['name']}")
        print(f"    File: {f['file']}")
        first_line = f['failure'].strip().splitlines()[-1] if f['failure'] else "Unknown failure"
        print(f"    Reason: {first_line}")
        print("    " + "-" * 70)


def main():
    parser = argparse.ArgumentParser(description="Run all bbr-v3-pro E2E tests.")
    parser.add_argument("--tier", choices=["1", "2", "3", "4"], help="Filter by tier number")
    parser.add_argument("--req", choices=["r1", "r2", "r3", "r4"], help="Filter by requirement (r1-r4)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose test execution output")
    parser.add_argument("-k", help="Pytest keyword expression")
    args = parser.parse_args()

    test_dir = get_test_dir()
    
    # Target test files
    files = [
        test_dir / "test_r1_cicd_build.py",
        test_dir / "test_r2_hyperv_config.py",
        test_dir / "test_r3_cve_detector.py",
        test_dir / "test_r4_install_script.py",
    ]

    if args.req:
        files = [f for f in files if f"_{args.req.lower()}_" in f.name]

    pytest_args = [str(f) for f in files]
    if args.verbose:
        pytest_args.append("-v")
    else:
        pytest_args.append("-q")

    if args.tier:
        pytest_args.extend(["-k", f"_t{args.tier}_"])
    elif args.k:
        pytest_args.extend(["-k", args.k])

    plugin = E2ECollectorPlugin()
    start_time = time.time()
    exit_code = pytest.main(pytest_args, plugins=[plugin])
    elapsed = time.time() - start_time

    print_matrix(plugin.results)
    print_failure_details(plugin.results)
    print(f"Total time elapsed: {elapsed:.2f} seconds\n")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
