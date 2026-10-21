# Contract for the post-deployment recap and the local commands file.
#
# Every provider is mocked: no AWS call, no file written, and no real state is
# read or changed (terraform test keeps its own in-memory state). Driven by
# tests/test_commands_file.py.

mock_provider "aws" {
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = {
      locations = ["eu-south-2a"]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_eip" {
    defaults = {
      public_ip = "203.0.113.10"
    }
  }
}

mock_provider "http" {}

mock_provider "local" {}

variables {
  aws_region          = "eu-south-2"
  allowed_ssh_cidr    = "203.0.113.4/32"
  ssh_public_key_path = "tests/fixtures/dummy_key.pub"
}

run "commands_file_with_aws_vault" {
  command = apply

  variables {
    aws_vault_profile = "wireguard"
  }

  assert {
    condition     = local_file.commands.filename == "./vpn-commands-eu-south-2.txt"
    error_message = "The commands file must be named after the region, at the repository root."
  }

  assert {
    condition     = local_file.commands.file_permission == "0600"
    error_message = "The commands file must be mode 0600."
  }

  assert {
    condition     = local_file.commands.content == output.next_steps
    error_message = "The file and the next_steps output must come from the same source."
  }

  assert {
    condition     = strcontains(local_file.commands.content, "terraform workspace select default && aws-vault exec --no-session wireguard -- terraform destroy -var='aws_region=eu-south-2'")
    error_message = "The destroy command must select the workspace, go through aws-vault and carry the deployed region."
  }

  assert {
    condition = alltrue([
      for marker in ["privatekey", "presharedkey", "[interface]", "[peer]", "begin openssh"] :
      !strcontains(lower(local_file.commands.content), marker)
    ])
    error_message = "The recap must hold no key material and no .conf content."
  }
}

run "commands_file_without_aws_vault" {
  command = apply

  assert {
    condition     = strcontains(local_file.commands.content, "terraform workspace select default && terraform destroy -var='aws_region=eu-south-2'")
    error_message = "Without an aws-vault profile, the destroy command must be rendered without the prefix."
  }

  assert {
    condition     = !strcontains(local_file.commands.content, "aws-vault")
    error_message = "No aws-vault command may be rendered when no profile is set."
  }
}

run "reject_shell_syntax_in_profile" {
  command = plan

  variables {
    aws_vault_profile = "wireguard; touch /tmp/pwned"
  }

  expect_failures = [var.aws_vault_profile]
}
