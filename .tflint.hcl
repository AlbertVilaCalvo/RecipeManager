# TFLint configuration for RecipeManager
# Docs: https://github.com/terraform-linters/tflint/blob/master/docs/user-guide/config.md

plugin "aws" {
  enabled = true
  version = "0.36.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Warn on deprecated index syntax (foo.0.bar → foo[0].bar)
rule "terraform_deprecated_index" {
  enabled = true
}

# Warn on unused declarations
rule "terraform_unused_declarations" {
  enabled = true
}

# Warn on missing module source version constraints
rule "terraform_module_pinned_source" {
  enabled = false # All modules are local paths, not public registry modules
}
