import json
import shutil
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class RepositoryHygieneTest(unittest.TestCase):
    def test_agent_and_graph_artifacts_are_ignored(self):
        for candidate in (
            ".claude/session.md",
            ".codex/config.toml",
            "graphify-out/graph.json",
            "tests/__pycache__/test_security.cpython-315.pyc",
            "vpn-commands-eu-west-3.txt",
        ):
            result = subprocess.run(
                ["git", "check-ignore", "--quiet", candidate],
                cwd=REPO_ROOT,
                check=False,
            )
            self.assertEqual(result.returncode, 0, candidate)

    @unittest.skipUnless(shutil.which("trivy"), "Trivy is not installed")
    def test_accepted_trivy_findings_are_scoped_to_their_resources(self):
        result = subprocess.run(
            [
                "trivy",
                "config",
                ".",
                "--format",
                "json",
                "--ignorefile",
                "/dev/null",
                "--skip-check-update",
                "--disable-telemetry",
                "--quiet",
            ],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        report = json.loads(result.stdout)
        finding_ids = {
            finding["ID"]
            for scan_result in report.get("Results", [])
            for finding in scan_result.get("Misconfigurations") or []
        }

        self.assertNotIn("AWS-0104", finding_ids)
        self.assertNotIn("AWS-0164", finding_ids)


if __name__ == "__main__":
    unittest.main()
