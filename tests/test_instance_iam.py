import re
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def terraform_sources():
    return "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(REPO_ROOT.glob("*.tf"))
    )


class InstanceIamTest(unittest.TestCase):
    def test_instance_policy_is_session_manager_only(self):
        # Every provider is mocked in the .tftest.hcl file: no AWS call and no
        # file written. Needs `terraform init`, which CI runs before the tests.
        result = subprocess.run(
            [
                "terraform",
                f"-chdir={REPO_ROOT}",
                "test",
                "-filter=tests/instance_iam.tftest.hcl",
                "-no-color",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_no_other_policy_reaches_the_instance_role(self):
        # The plan test checks the inline policy; this keeps a second grant,
        # such as a managed policy attachment, from being added beside it.
        sources = terraform_sources()

        self.assertNotIn("policy/AmazonSSMManagedInstanceCore", sources)
        self.assertNotIn('resource "aws_iam_role_policy_attachment"', sources)
        self.assertNotIn('resource "aws_iam_policy"', sources)
        self.assertNotIn("managed_policy_arns", sources)
        self.assertNotIn("inline_policy", sources)
        self.assertEqual(
            re.findall(r'resource "aws_iam_role_policy" "(\w+)"', sources),
            ["session_manager"],
        )


if __name__ == "__main__":
    unittest.main()
