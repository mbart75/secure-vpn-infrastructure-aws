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


    def test_instance_type_rejects_malformed_values(self):
        result = self.run_variable_test(
            """
            run "reject_malformed_instance_type" {
              command = plan

              variables {
                instance_type = "t3.micro; reboot"
              }

              expect_failures = [var.instance_type]
            }
            """
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_instance_type_accepts_real_type_names(self):
        for instance_type in ("t3.micro", "t3a.small", "m7i-flex.large", "u-6tb1.metal"):
            with self.subTest(instance_type=instance_type):
                result = self.run_variable_test(
                    f"""
                    run "accept_instance_type" {{
                      command = plan

                      variables {{
                        instance_type = "{instance_type}"
                      }}
                    }}
                    """
                )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # Every other input rendered into scripts/user_data.sh by templatefile().
    # client_dns_servers is covered above; server_public_ip comes from the EIP.

    def test_project_name_rejects_shell_syntax(self):
        result = self.run_variable_test(
            r"""
            run "reject_shell_syntax_in_project_name" {
              command = plan

              variables {
                project_name = "vpn\"; touch /tmp/pwned #"
              }

              expect_failures = [var.project_name]
            }
            """
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_wireguard_clients_rejects_shell_syntax(self):
        result = self.run_variable_test(
            r"""
            run "reject_shell_syntax_in_client_name" {
              command = plan

              variables {
                wireguard_clients = ["phone", "laptop$(reboot)"]
              }

              expect_failures = [var.wireguard_clients]
            }
            """
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_vpn_network_cidr_rejects_anything_but_an_ipv4_cidr(self):
        for value in ("10.8.0.0/24; reboot", "fd00::/64"):
            with self.subTest(vpn_network_cidr=value):
                result = self.run_variable_test(
                    f"""
                    run "reject_vpn_network_cidr" {{
                      command = plan

                      variables {{
                        vpn_network_cidr = "{value}"
                      }}

                      expect_failures = [var.vpn_network_cidr]
                    }}
                    """
                )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ports_reject_out_of_range_values(self):
        # Both are typed as numbers, so a string never reaches the template.
        for variable in ("ssh_port", "wireguard_port"):
            for value in (0, 65536):
                with self.subTest(variable=variable, value=value):
                    result = self.run_variable_test(
                        f"""
                        run "reject_out_of_range_port" {{
                          command = plan

                          variables {{
                            {variable} = {value}
                          }}

                          expect_failures = [var.{variable}]
                        }}
                        """
                    )

                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
