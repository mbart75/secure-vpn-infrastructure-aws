import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class TerraformInputValidationTest(unittest.TestCase):
    def run_variable_test(self, test_body):
        with tempfile.TemporaryDirectory(prefix="secure-vpn-terraform-test-") as temp_dir:
            fixture = Path(temp_dir)
            shutil.copy2(REPO_ROOT / "variables.tf", fixture / "variables.tf")
            tests_dir = fixture / "tests"
            tests_dir.mkdir()
            (tests_dir / "client_dns_validation.tftest.hcl").write_text(
                textwrap.dedent(test_body),
                encoding="utf-8",
            )

            return subprocess.run(
                ["terraform", f"-chdir={fixture}", "test", "-no-color"],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_client_dns_servers_rejects_shell_syntax(self):
        result = self.run_variable_test(
            r"""
            run "reject_shell_syntax_in_dns_server" {
              command = plan

              variables {
                client_dns_servers = ["1.1.1.1\"; DNS_INJECTION_MARKER=\"rendered\" #"]
              }

              expect_failures = [var.client_dns_servers]
            }
            """
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_client_dns_servers_accepts_ipv4_and_ipv6(self):
        result = self.run_variable_test(
            """
            run "accept_ipv4_and_ipv6_dns_servers" {
              command = plan

              variables {
                client_dns_servers = ["1.1.1.1", "2606:4700:4700::1111"]
              }
            }
            """
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_client_dns_servers_rejects_an_empty_list(self):
        result = self.run_variable_test(
            """
            run "reject_empty_dns_server_list" {
              command = plan

              variables {
                client_dns_servers = []
              }

              expect_failures = [var.client_dns_servers]
            }
            """
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
