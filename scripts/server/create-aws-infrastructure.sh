#!/bin/bash
#
# Create AWS infrastructure for the Recipe Manager server
#
# Usage:
#   ./scripts/server/create-aws-infrastructure.sh <environment>
#
# Usage examples:
#   ./scripts/server/create-aws-infrastructure.sh dev    # Create dev infrastructure
#   ./scripts/server/create-aws-infrastructure.sh prod   # Create prod infrastructure
#
# Arguments:
#   environment - The deployment environment (dev or prod)
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - Terraform installed
#   - Helm installed
#   - kubectl installed
#   - Route53 hosted zone for the API domain exists in AWS

set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

# ============================================================================
# Configuration
# ============================================================================

ENVIRONMENT="${1:-}"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform/server/environments/${ENVIRONMENT}"

# ============================================================================
# Validation
# ============================================================================

# Validate required argument
if [[ -z "${ENVIRONMENT}" ]]; then
  log_error "Environment is required."
  log_error "Usage: ./scripts/server/create-aws-infrastructure.sh <environment>"
  log_error "Example: ./scripts/server/create-aws-infrastructure.sh dev"
  exit 1
fi

validate_environment "${ENVIRONMENT}"

validate_directory_exists "${TERRAFORM_DIR}"

validate_command_exists terraform
validate_command_exists aws
validate_command_exists helm
validate_command_exists kubectl

# ============================================================================
# Main Script
# ============================================================================

log_info "Creating AWS infrastructure for environment: ${ENVIRONMENT}"
echo ""

cd "${TERRAFORM_DIR}" || exit 1

# Step 1: Initialize Terraform
log_step "Step 1/5: Initializing Terraform..."
validate_file_exists "${TERRAFORM_DIR}/backend.config" "backend.config not found at ${TERRAFORM_DIR}/backend.config. Please run scripts/bootstrap/create-state-bucket.sh ${ENVIRONMENT} first to create the state bucket and backend.config file."

log_info "Using backend config from backend.config"
terraform init -backend-config="backend.config"

# Step 2: Create core infrastructure (VPC, EKS, RDS, ECR, Pod Identity, ACM Certificate, App Secrets)
log_step "Step 2/5: Creating core infrastructure (VPC, EKS, RDS, ECR, Pod Identity, ACM Certificate, App Secrets, External Secrets IAM role, GitHub Actions OIDC role)..."
log_info "This may take 15-20 minutes..."
terraform apply \
  -target=module.vpc \
  -target=module.eks \
  -target=module.rds \
  -target=module.ecr \
  -target=module.pod_identity \
  -target=module.acm_certificates \
  -target=module.app_secrets \
  -target=module.external_secrets \
  -target=module.github_actions_oidc_role_server \
  -auto-approve

# Step 3: Install Kubernetes controllers using Helm
log_step "Step 3/5: Installing Load Balancer Controller, ExternalDNS, Karpenter and Argo CD Helm charts..."
log_info "This may take 5-10 minutes..."

# Download Helm charts locally to avoid network timeouts during Terraform apply
download_helm_charts

# Retry logic for network timeouts when downloading Helm charts
retry_with_backoff 3 "Install Kubernetes controllers and Argo CD using Helm" \
  terraform apply \
  -target=module.lb_controller \
  -target=module.external_dns \
  -target=module.karpenter_controller \
  -target=module.argocd \
  -auto-approve

# Step 4: Create Argo CD root Application (App of Apps)
# The Argo CD CRDs need to be installed before creating the root Application.
# The root Application deploys External Secrets Operator, the Karpenter NodePool + EC2NodeClass
# (which provisions worker nodes) and the server app.
log_step "Step 4/5: Creating Argo CD root Application (App of Apps)..."
log_info "This deploys External Secrets Operator, the Karpenter NodePool + EC2NodeClass (which provisions worker nodes) and the server app"
terraform apply -target=module.argocd_apps -auto-approve

# Step 5: Update kubectl config
log_step "Step 5/5: Updating kubectl configuration..."
AWS_REGION=$(get_tfvars_value "aws_region")
CLUSTER_NAME=$(get_terraform_output "cluster_name")
NAMESPACE="recipe-manager"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

# Set default namespace for context to avoid specifying -n each time
kubectl config set-context "arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}" --namespace "${NAMESPACE}"

# Display summary
echo ""
echo "=========================================="
echo "Infrastructure Creation Complete!"
echo "=========================================="
echo ""

log_info "Infrastructure summary:"
terraform output

WEB_DOMAIN=$(get_tfvars_value "web_domain")
ARGOCD_DOMAIN=$(get_tfvars_value "argocd_domain")
API_DOMAIN=$(get_tfvars_value "api_domain")

echo ""
log_info "Website: https://${WEB_DOMAIN}"
log_info "Argo CD UI: https://${ARGOCD_DOMAIN}"
log_info "API: https://${API_DOMAIN}"
echo ""
log_info "Get the Argo CD admin password with either:"
echo "  argocd admin initial-password -n argocd"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
log_info "Log in to Argo CD:"
echo "  argocd login ${ARGOCD_DOMAIN} --username admin"
echo ""
log_info "To deploy manually do:"
echo "  1. Build and push the Docker image to ECR:"
echo "     ./scripts/server/build-push-image-ecr.sh ${ENVIRONMENT}"
echo "  2. Deploy the server application (apply Kubernetes manifests):"
echo "     ./scripts/server/deploy-server-eks.sh ${ENVIRONMENT} <image_tag>"
echo ""
