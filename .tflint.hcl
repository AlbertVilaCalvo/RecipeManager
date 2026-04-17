# TFLint configuration
# https://github.com/terraform-linters/tflint/tree/master/docs/user-guide

config {
  # https://github.com/terraform-linters/tflint/blob/master/docs/user-guide/calling-modules.md
  call_module_type = "local"
}

# Rules: https://github.com/terraform-linters/tflint-ruleset-terraform/blob/main/docs/rules/README.md
plugin "terraform" {
  enabled = true
  version = "0.14.1"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
  preset  = "all" # Enable all rules
}

# Rules: https://github.com/terraform-linters/tflint-ruleset-aws/blob/master/docs/rules/README.md
# TODO enable deep checking: https://github.com/terraform-linters/tflint-ruleset-aws/blob/master/docs/deep_checking.md
plugin "aws" {
  enabled = true
  version = "0.47.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Disable "Module should include a main.tf file as the primary entrypoint"
# https://github.com/terraform-linters/tflint-ruleset-terraform/blob/main/docs/rules/terraform_standard_module_structure.md
rule "terraform_standard_module_structure" {
  enabled = false
}
