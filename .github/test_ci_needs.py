"""Exercise the dependency guard with data fixtures, without changing repo files."""

import unittest

import yaml

from check_ci_needs import check_needs


class NeedsTests(unittest.TestCase):
    def test_all_jobs_covered(self):
        check_needs(yaml.safe_load("""
jobs:
  rust: {}
  lint: {}
  integration: {}
  ci:
    needs: [rust, lint, integration]
"""))

    def test_new_job_requires_dependency(self):
        with self.assertRaisesRegex(ValueError, "missing: security"):
            check_needs({"jobs": {
                "lint": {}, "security": {}, "ci": {"needs": ["lint"]},
            }})

    def test_new_job_is_covered(self):
        check_needs({"jobs": {
            "lint": {}, "security": {}, "ci": {"needs": ["lint", "security"]},
        }})

    def test_unknown_dependency(self):
        with self.assertRaisesRegex(ValueError, "unexpected: stale"):
            check_needs({"jobs": {
                "lint": {}, "ci": {"needs": ["lint", "stale"]},
            }})

    def test_self_dependency(self):
        with self.assertRaisesRegex(ValueError, "unexpected: ci"):
            check_needs({"jobs": {"lint": {}, "ci": {"needs": ["lint", "ci"]}}})

    def test_missing_aggregate(self):
        with self.assertRaisesRegex(ValueError, "missing ci job"):
            check_needs({"jobs": {"lint": {}}})

    def test_missing_needs(self):
        with self.assertRaisesRegex(ValueError, "missing: lint"):
            check_needs({"jobs": {"lint": {}, "ci": {}}})

    def test_single_dependency(self):
        check_needs({"jobs": {"lint": {}, "ci": {"needs": "lint"}}})

    def test_yaml_block_list_and_quoted_job(self):
        check_needs(yaml.safe_load("""
jobs:
  'security-scan': {}
  ci:
    needs:
      - security-scan
"""))


if __name__ == "__main__":
    unittest.main()
