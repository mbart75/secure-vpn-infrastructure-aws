import json
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def documented_iam_policy():
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    iam_section = readme.split('<a id="iam-setup"></a>', 1)[1]
    policy_block = re.search(r"```json\n(.*?)\n```", iam_section, re.DOTALL)
    if policy_block is None:
        raise AssertionError("README IAM policy JSON block is missing")
    return json.loads(policy_block.group(1))


def statements_for_action(policy, action):
    matches = []
    for statement in policy["Statement"]:
        actions = statement.get("Action", [])
        if isinstance(actions, str):
            actions = [actions]
        if action in actions:
            matches.append(statement)
    return matches


class IamPolicyTest(unittest.TestCase):
    def test_start_session_is_limited_to_the_vpn_project_tag(self):
        statements = statements_for_action(documented_iam_policy(), "ssm:StartSession")

        self.assertTrue(statements)
        project_instance_grant_found = False
        for statement in statements:
            project_tag = (
                statement.get("Condition", {})
                .get("StringEquals", {})
                .get("ssm:resourceTag/Project")
            )
            resources = statement.get("Resource", [])
            if isinstance(resources, str):
                resources = [resources]

            if project_tag == "wireguard-vpn":
                project_instance_grant_found = True
                self.assertEqual(resources, ["arn:aws:ec2:*:*:instance/*"])
            else:
                self.assertEqual(
                    resources,
                    ["arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell"],
                )

        self.assertTrue(project_instance_grant_found)

    def test_session_control_is_limited_to_the_callers_sessions(self):
        # IAM users open sessions named after ${aws:username}; the AWS samples
        # use ${aws:userid} for federated callers.
        expected_resources = [
            "arn:aws:ssm:*:*:session/${aws:username}-*",
            "arn:aws:ssm:*:*:session/${aws:userid}-*",
        ]

        for action in ("ssm:ResumeSession", "ssm:TerminateSession"):
            statements = statements_for_action(documented_iam_policy(), action)
            self.assertEqual(len(statements), 1)
            self.assertEqual(statements[0].get("Resource"), expected_resources)

    def test_project_roles_can_only_be_granted_inside_the_boundary(self):
        # CreateRole, PutRolePolicy or PutRolePermissionsBoundary without this
        # condition let the deploy key write an administrator policy on a
        # wireguard-* role, pass it to an instance and read it from IMDS.
        boundary = "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
        policy = documented_iam_policy()

        for action in (
            "iam:CreateRole",
            "iam:PutRolePolicy",
            "iam:PutRolePermissionsBoundary",
        ):
            with self.subTest(action=action):
                statements = statements_for_action(policy, action)
                self.assertEqual(len(statements), 1)
                self.assertEqual(
                    statements[0].get("Condition"),
                    {"ArnEquals": {"iam:PermissionsBoundary": boundary}},
                )

    def test_boundary_cannot_be_bypassed(self):
        policy = documented_iam_policy()

        for action in (
            "iam:AttachRolePolicy",
            "iam:DeleteRolePermissionsBoundary",
            "iam:CreatePolicy",
            "iam:CreatePolicyVersion",
            "iam:UpdateAssumeRolePolicy",
        ):
            with self.subTest(action=action):
                self.assertEqual(statements_for_action(policy, action), [])

        for statement in policy["Statement"]:
            actions = statement["Action"]
            if isinstance(actions, str):
                actions = [actions]
            self.assertFalse(
                [action for action in actions if action.startswith("iam:") and "*" in action],
                statement["Sid"],
            )

    def test_instance_role_boundary_matches_the_deploy_policy(self):
        main_tf = (REPO_ROOT / "main.tf").read_text(encoding="utf-8")

        self.assertIn(
            'instance_permissions_boundary = "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"',
            main_tf,
        )


if __name__ == "__main__":
    unittest.main()
