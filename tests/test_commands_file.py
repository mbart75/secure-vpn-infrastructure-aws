import re
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class CommandsFileTest(unittest.TestCase):
    def test_recap_and_commands_file_contract(self):
        # Every provider is mocked in the .tftest.hcl file: no AWS call and no
        # file written. Needs `terraform init`, which CI runs before the tests.
        result = subprocess.run(
            [
                "terraform",
                f"-chdir={REPO_ROOT}",
                "test",
                "-filter=tests/commands_file.tftest.hcl",
                "-no-color",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_deploy_script_does_not_write_its_own_destroy_command(self):
        script = (REPO_ROOT / "deploy.command").read_text(encoding="utf-8")

        self.assertNotIn("terraform destroy", script)
        self.assertIn("terraform output -raw next_steps", script)

    def test_deploy_script_renders_commands_with_its_aws_vault_profile(self):
        script = (REPO_ROOT / "deploy.command").read_text(encoding="utf-8")

        self.assertRegex(script, r'(?m)^AWS_PROFILE_NAME="wireguard"$')
        self.assertTrue(
            re.search(r'-var="aws_vault_profile=\$AWS_PROFILE_NAME"', script),
            "deploy.command must pass its aws-vault profile to Terraform",
        )


if __name__ == "__main__":
    unittest.main()
