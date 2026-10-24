import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class ClientRevocationTest(unittest.TestCase):
    def test_user_data_change_replaces_the_server(self):
        # Every provider is mocked in the .tftest.hcl file: no AWS call and no
        # file written. Needs `terraform init`, which CI runs before the tests.
        result = subprocess.run(
            [
                "terraform",
                f"-chdir={REPO_ROOT}",
                "test",
                "-filter=tests/client_revocation.tftest.hcl",
                "-no-color",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
