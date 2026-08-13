import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class CiSecurityTest(unittest.TestCase):
    def test_external_actions_are_pinned_to_full_commit_shas(self):
        workflow = (REPO_ROOT / ".github/workflows/terraform.yml").read_text(
            encoding="utf-8"
        )
        action_refs = re.findall(r"^\s*uses:\s*[^@\s]+@([^\s#]+)", workflow, re.MULTILINE)

        self.assertTrue(action_refs)
        for action_ref in action_refs:
            self.assertRegex(action_ref, r"^[0-9a-f]{40}$")

    def test_trivy_archive_digest_is_anchored_in_the_workflow(self):
        workflow = (REPO_ROOT / ".github/workflows/terraform.yml").read_text(
            encoding="utf-8"
        )
        digest = re.search(r'^\s*TRIVY_SHA256:\s*"([0-9a-f]{64})"\s*$', workflow, re.MULTILINE)

        self.assertIsNotNone(digest)
        self.assertIn('echo "$TRIVY_SHA256  $archive" | sha256sum -c -', workflow)


if __name__ == "__main__":
    unittest.main()
