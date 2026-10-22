# TFLint configuration shared by every Terraform blueprint.
# CI runs: tflint --init --config "$GITHUB_WORKSPACE/.tflint.hcl"
#          tflint --config "$GITHUB_WORKSPACE/.tflint.hcl" --chdir <blueprint-dir>

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
