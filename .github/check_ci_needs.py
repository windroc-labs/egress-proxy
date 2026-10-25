"""Require CI to depend directly on every other job in ci.yml (PyYAML required)."""

from pathlib import Path
import sys

import yaml


def check_needs(workflow):
    jobs = workflow["jobs"]
    if "ci" not in jobs:
        raise ValueError("missing ci job")
    needs = jobs["ci"].get("needs", [])
    if isinstance(needs, str):
        needs = [needs]
    expected = set(jobs) - {"ci"}
    actual = set(needs)
    errors = []
    if expected - actual:
        errors.append("missing: " + ", ".join(sorted(expected - actual)))
    if actual - expected:
        errors.append("unexpected: " + ", ".join(sorted(actual - expected)))
    if errors:
        raise ValueError("ci.needs must include every other job; " + "; ".join(errors))


if __name__ == "__main__":
    try:
        workflow = Path(__file__).parent / "workflows" / "ci.yml"
        check_needs(yaml.safe_load(workflow.read_text()))
    except (OSError, yaml.YAMLError, KeyError, TypeError, ValueError) as error:
        sys.exit(f"FAIL ci_needs: {error}")
    print("ok ci_needs")
