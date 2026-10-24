# Contract: removing a device from wireguard_clients revokes it.
#
# The bootstrap script runs once, at first boot. A user_data change applied in
# place (stop, start) never reaches WireGuard, so the removed peer would keep
# its access. The server has to be replaced instead, which the AWS provider
# does when user_data_replace_on_change is set.
#
# The replacement itself cannot be exercised here: a mocked provider skips the
# provider's own plan logic, where that replacement is decided. The test pins
# the setting, for every device list, so dropping it fails CI.
#
# Every provider is mocked: no AWS call, no file written, and no real state is
# read or changed. Driven by tests/test_client_revocation.py.

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

run "default_devices" {
  command = plan

  assert {
    condition     = aws_instance.wireguard.user_data_replace_on_change == true
    error_message = "A user_data change must replace the instance: the bootstrap script only runs at first boot, so a removed device would keep its access."
  }
}

run "one_device_removed" {
  command = plan

  variables {
    wireguard_clients = ["phone"]
  }

  assert {
    condition     = aws_instance.wireguard.user_data_replace_on_change == true
    error_message = "A user_data change must replace the instance: the bootstrap script only runs at first boot, so a removed device would keep its access."
  }
}
