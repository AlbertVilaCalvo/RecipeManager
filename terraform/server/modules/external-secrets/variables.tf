# Common variables

variable "app_name" {
  description = "The application name"
  type        = string
}

variable "environment" {
  description = "The deployment environment (dev, prod)"
  type        = string
  validation {
    condition     = can(regex("^(dev|prod)$", var.environment))
    error_message = "The environment must be one of: dev, prod."
  }
}

# External Secrets Operator module variables

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "secrets_manager_secret_arns" {
  description = "List of AWS Secrets Manager secret ARNs that the External Secrets Operator is allowed to access"
  type        = list(string)
}

variable "ssm_parameter_arns" {
  description = "List of AWS SSM Parameter Store ARNs that the External Secrets Operator is allowed to access"
  type        = list(string)
}
