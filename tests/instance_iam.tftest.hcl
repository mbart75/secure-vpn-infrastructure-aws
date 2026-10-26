# Contract: the instance role grants Session Manager and nothing else.
#
# AmazonSSMManagedInstanceCore also grants ssm:GetParameter and
# ssm:GetParameters on every parameter of the account. The role carries the
# minimal Session Manager policy from the AWS documentation instead, inside a
# permissions boundary that the deploy policy in the README requires.
#
# Every provider is mocked: no AWS call, no file written, and no real state is
# read or changed. Driven by tests/test_instance_iam.py.

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

run "instance_role_is_session_manager_only" {
  command = plan

  assert {
    condition = toset(flatten([
      for statement in data.aws_iam_policy_document.session_manager.statement : statement.actions
      ])) == toset([
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ])
    error_message = "The instance policy must hold exactly the five Session Manager actions from the AWS documentation."
  }

  assert {
    condition = length([
      for statement in data.aws_iam_policy_document.session_manager.statement : statement
      if statement.effect != "Allow" || length(coalesce(statement.not_actions, [])) > 0
    ]) == 0
    error_message = "The instance policy must use plain Allow statements with an explicit action list, no NotAction."
  }

  assert {
    condition = alltrue([
      for action in flatten([
        for statement in data.aws_iam_policy_document.session_manager.statement : statement.actions
      ]) : !startswith(lower(action), "ssm:getparameter") && !strcontains(action, "*")
    ])
    error_message = "The instance policy must not grant ssm:GetParameter* or any wildcard action."
  }

  assert {
    condition     = aws_iam_role.wireguard.permissions_boundary == "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
    error_message = "The instance role must carry the boundary the README deploy policy requires, or CreateRole is denied."
  }

  assert {
    condition = (
      aws_iam_role.wireguard.name_prefix == "wireguard-vpn-" &&
      aws_iam_instance_profile.wireguard.name_prefix == "wireguard-vpn-"
    )
    error_message = "With the default project_name, the role and instance profile must be named wireguard-vpn-*, the only prefix the README deploy policy grants."
  }

  assert {
    condition     = aws_iam_role_policy.session_manager.policy == data.aws_iam_policy_document.session_manager.json
    error_message = "The inline policy on the instance role must be the Session Manager policy document."
  }
}
