# Contributing to AgentCore Blueprints

Thanks for your interest in adding a blueprint. This page covers where blueprints live,
what each one needs, and the checks that run on every pull request.

## Where blueprints live

Group blueprints by how they are built and deployed. Put each one in its own folder:

| Approach | Folder |
| --- | --- |
| AgentCore CLI or AWS CLI scripts | `agentcore-cli/<blueprint-name>/` |
| Terraform | `infrastructure-as-code/terraform/<blueprint-name>/` |
| AWS CDK | `infrastructure-as-code/cdk/<blueprint-name>/` |
| AWS CloudFormation | `infrastructure-as-code/cloudformation/<blueprint-name>/` |

If your blueprint doesn't fit any of these (for example a notebook or a standalone
agent), propose a new top-level folder in your pull request. Create folders only when a
blueprint ships in them.

## What every blueprint needs

Each blueprint must be self-contained and include a `README.md` covering:

- Overview of what it deploys and why
- Architecture diagram, if available
- Prerequisites: tooling and versions, Regions, IAM permissions
- Deploy steps
- Test or verify steps
- Cleanup or destroy steps
- Cost notes

Then add a row for it to the matching table in the root [README](README.md#blueprints).

## Keep secrets and account details out

- Never commit credentials, API keys, or your AWS account ID. Derive account and Region
  at runtime (for example `aws sts get-caller-identity` or
  `data.aws_caller_identity` in Terraform), and use `123456789012` in examples.
- Take AWS profiles and Regions as arguments or variables rather than hardcoding them.
- Ship `*.example` files for anything environment-specific (for example
  `terraform.tfvars.example`, `backend.tf.example`).
- Add a `.gitignore` to the blueprint folder for local state and build output, such as
  `terraform.tfstate*`, `.terraform/`, generated project folders, and `.env` files.

## Checks on pull requests

Every pull request and push to `main` runs these checks:

| Check | Runs on | Fails the build when |
| --- | --- | --- |
| Gitleaks secret scan | Every commit | A secret or AWS account ID is found |
| Trivy IaC scan | Changed blueprint folders | A HIGH or CRITICAL finding is not suppressed |
| `terraform fmt`, `terraform validate`, TFLint | Changed Terraform blueprints | Formatting, validation, or lint fails |
| cfn-lint | Changed CloudFormation blueprints | A template is invalid |
| CodeQL | Python changes, plus weekly | Reports alerts to the Security tab for review |

Lower-severity Trivy findings also appear in the repository's Security tab.

To run the Terraform checks locally from the repository root before you push:

```bash
DIR=infrastructure-as-code/terraform/<blueprint-name>
terraform -chdir="$DIR" fmt -check -recursive
terraform -chdir="$DIR" init -backend=false
terraform -chdir="$DIR" validate
tflint --init --config "$PWD/.tflint.hcl"
tflint --config "$PWD/.tflint.hcl" --chdir "$DIR"
```

## Suppressing a finding

If a finding is an acceptable tradeoff for a sample, suppress it and always write down why:

- Terraform: put a `#trivy:ignore:<ID>` comment, with a reason comment above it, on the
  line directly above the `resource` block. A blank line in between breaks it.
- Dockerfiles and anything else: add an entry with a `statement` explaining the reason
  to the blueprint's `.trivyignore.yaml`.

Don't suppress a finding that is a real security problem. Fix it, or raise it in the pull
request so it can be discussed.

## Opening a pull request

1. Fork the repository and create a branch for your blueprint.
2. Add your blueprint folder and its row in the root README.
3. Open a pull request describing what the blueprint shows and how you tested it.
