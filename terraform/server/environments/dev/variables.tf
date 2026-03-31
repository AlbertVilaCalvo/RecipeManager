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

variable "aws_region" {
  description = "The AWS region to deploy the resources to"
  type        = string
  validation {
    condition     = can(regex("^(us|eu|ap|sa|ca|me|af)-(east|west|north|south|central|northeast|southeast|northwest|southwest)-[1-3]$", var.aws_region))
    error_message = "The region must be a valid AWS region (e.g., us-east-1, eu-west-2)."
  }
}

variable "additional_default_tags" {
  description = "Additional default tags, in addition to Application and Environment"
  type        = map(string)
  default     = {}
  validation {
    condition     = length([for k in keys(var.additional_default_tags) : k if k == "Application" || k == "Environment"]) == 0
    error_message = "additional_default_tags must not contain the keys \"Application\" or \"Environment\" as they are already set"
  }
}

variable "web_domain" {
  description = "The website domain name (e.g., recipemanager.link)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\\.[a-z]{2,}$", var.web_domain))
    error_message = "The web domain must be a valid domain name."
  }
}

variable "server_hosted_zone_name" {
  description = "The Route53 hosted zone name used by the server ACM certificates and ExternalDNS"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\\.[a-z]{2,}$", var.server_hosted_zone_name))
    error_message = "The server hosted zone name must be a valid domain name."
  }
}

variable "api_domain" {
  description = "The API endpoint domain name (e.g., api.recipemanager.link)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\\.[a-z]{2,}$", var.api_domain))
    error_message = "The API domain must be a valid domain name."
  }
  validation {
    condition     = var.api_domain == var.server_hosted_zone_name || endswith(var.api_domain, ".${var.server_hosted_zone_name}")
    error_message = "The API domain must be equal to the server hosted zone name or be a subdomain of it."
  }
}

variable "argocd_domain" {
  description = "The Argo CD domain name (e.g., argocd.recipemanager.link)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\\.[a-z]{2,}$", var.argocd_domain))
    error_message = "The Argo CD domain must be a valid domain name."
  }
  validation {
    condition     = var.argocd_domain == var.server_hosted_zone_name || endswith(var.argocd_domain, ".${var.server_hosted_zone_name}")
    error_message = "The Argo CD domain must be equal to the server hosted zone name or be a subdomain of it."
  }
}

# VPC

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block"
  }
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway for all private subnets (cost savings for dev)"
  type        = bool
}

# EKS

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be in format X.Y (e.g., 1.34)"
  }
}

variable "endpoint_public_access" {
  description = "Enable public access to the EKS API endpoint"
  type        = bool
}

variable "public_access_cidrs" {
  description = "List of CIDR blocks allowed to access the EKS API endpoint publicly"
  type        = list(string)
}

variable "node_instance_types" {
  description = "List of EC2 instance types for the managed node group"
  type        = list(string)
  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "At least one instance type must be specified (e.g., [\"t3.medium\"])"
  }
}

variable "node_group_min_size" {
  description = "Minimum number of nodes in the node group"
  type        = number
  validation {
    condition     = var.node_group_min_size >= 1 && var.node_group_min_size <= 10
    error_message = "node_group_min_size must be between 1 and 10"
  }
}

variable "node_group_max_size" {
  description = "Maximum number of nodes in the node group"
  type        = number
  validation {
    condition     = var.node_group_max_size >= 1 && var.node_group_max_size <= 10
    error_message = "node_group_max_size must be between 1 and 10"
  }
}

variable "node_group_desired_size" {
  description = "Desired number of nodes in the node group"
  type        = number
  validation {
    condition     = var.node_group_desired_size >= 1 && var.node_group_desired_size <= 10
    error_message = "node_group_desired_size must be between 1 and 10"
  }
}

variable "node_disk_size" {
  description = "Disk size in GB for worker nodes"
  type        = number
}

variable "node_capacity_type" {
  description = "Capacity type for the node group (ON_DEMAND for prod, and SPOT or ON_DEMAND for dev/staging)"
  type        = string
  validation {
    condition = (
      var.environment == "prod" ? var.node_capacity_type == "ON_DEMAND"
      : contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    )
    error_message = "If environment is prod, node_capacity_type must be ON_DEMAND; otherwise it must be ON_DEMAND or SPOT."
  }
}

variable "log_retention_days" {
  description = "Retention period in days for the CloudWatch Log Group (e.g. 0 for dev, 30 for prod)"
  type        = number
}

# RDS

variable "database_name" {
  description = "Name of the database to create. 1 to 63 letters, underscores or digits. Must begin with a letter"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must start with a letter and contain only letters, digits, or underscores, with a maximum length of 63 characters"
  }
}

variable "master_username" {
  description = "Master username for the database"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in GB"
  type        = number
}

variable "db_max_allocated_storage" {
  description = "Maximum allocated storage for autoscaling in GB"
  type        = number
}


variable "engine_version" {
  description = "PostgreSQL engine version"
  type        = string
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
}

variable "backup_retention_period" {
  description = "Number of days to retain backups"
  type        = number
}

variable "backup_window" {
  description = "Preferred backup window"
  type        = string
}

variable "maintenance_window" {
  description = "Preferred maintenance window"
  type        = string
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot when deleting"
  type        = bool
}

# App Secrets

# Used in RDS master password too
variable "secretsmanager_secret_recovery_days" {
  description = "Number of days to retain secrets in Secrets Manager after deletion (e.g., 7 for dev, 30 for prod). Use 0 if you recreate infrastructure to avoid 'InvalidRequestException: you can't create this secret because a secret with this name is already scheduled for deletion'."
  type        = number
}

# LB Controller

variable "lb_controller_chart_version" {
  description = "Version of the AWS Load Balancer Controller Helm chart"
  type        = string
}

# ExternalDNS

variable "external_dns_chart_version" {
  description = "Version of the ExternalDNS Helm chart"
  type        = string
}

# Karpenter Controller

variable "karpenter_chart_version" {
  description = "Version of the Karpenter Helm chart"
  type        = string
}

# Argo CD

variable "argocd_chart_version" {
  description = "Version of the Argo CD Helm chart"
  type        = string
}

variable "git_repo_url" {
  description = "URL of the Git repository containing Argo CD Application manifests"
  type        = string
}

variable "git_revision" {
  description = "Git revision (branch, tag, or commit) to sync from"
  type        = string
}

# Email Configuration

variable "email_user" {
  description = "Email address for sending application emails"
  type        = string
}

variable "email_password" {
  description = "Password for the email account"
  type        = string
  sensitive   = true
}

# GitHub Actions OIDC

variable "github_org" {
  description = "The GitHub organization or username that owns the repository"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.github_org))
    error_message = "The GitHub organization name must contain only alphanumeric characters, underscores, and hyphens."
  }
}

variable "github_repo" {
  description = "The GitHub repository name"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.github_repo))
    error_message = "The GitHub repository name must contain only alphanumeric characters, underscores, hyphens, and periods."
  }
}
