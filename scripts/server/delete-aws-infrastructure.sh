#!/bin/bash
#
# Delete AWS infrastructure for the Recipe Manager server
#
# Usage:
#   ./scripts/server/delete-aws-infrastructure.sh <environment>
#
# Usage examples:
#   ./scripts/server/delete-aws-infrastructure.sh dev    # Delete dev infrastructure
#   ./scripts/server/delete-aws-infrastructure.sh prod   # Delete prod infrastructure
#
# Arguments:
#   environment - The deployment environment (dev or prod)
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - Terraform installed
#   - Helm installed
#   - kubectl installed
#   - Docker installed and running (optional, for cleaning up local images)
#
# WARNING: This will permanently delete all infrastructure resources, including the ECR images!

set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

# ============================================================================
# Configuration
# ============================================================================

ENVIRONMENT="${1}"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform/server/environments/${ENVIRONMENT}"

# ============================================================================
# Validation
# ============================================================================

# Validate required argument
if [[ -z "${ENVIRONMENT}" ]]; then
  log_error "Environment is required."
  log_error "Usage: ./scripts/server/delete-aws-infrastructure.sh <environment>"
  log_error "Example: ./scripts/server/delete-aws-infrastructure.sh dev"
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

log_warn "WARNING: This will permanently delete ALL infrastructure for environment: ${ENVIRONMENT}"
log_warn "This includes: VPC, EKS cluster, RDS database, ECR repository, and all associated resources."
echo ""
read -p "Are you sure you want to continue? Type 'yes' to proceed: " -r
echo ""

if [[ ! $REPLY =~ ^yes$ ]]; then
  log_info "Deletion cancelled."
  exit 0
fi

log_info "Starting infrastructure deletion for environment: ${ENVIRONMENT}"
echo ""

cd "${TERRAFORM_DIR}" || exit 1

# Initialize Terraform
log_info "Initializing Terraform..."
validate_file_exists "${TERRAFORM_DIR}/backend.config" "backend.config not found at ${TERRAFORM_DIR}/backend.config. Please run scripts/bootstrap/create-state-bucket.sh ${ENVIRONMENT} first to create the state bucket and backend.config file."

log_info "Using backend config from backend.config"
terraform init -backend-config="backend.config"

CLUSTER_NAME=$(get_terraform_output "cluster_name")
ECR_REPOSITORY_URL=$(get_terraform_output "ecr_repository_url")
API_DOMAIN=$(get_tfvars_value "api_domain")
ARGOCD_DOMAIN=$(get_tfvars_value "argocd_domain")
AWS_REGION=$(get_tfvars_value "aws_region")

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
  log_error "Could not get AWS account ID from AWS CLI."
  exit 1
fi

log_info "Cluster Name: ${CLUSTER_NAME}"
log_info "ECR Repository URL: ${ECR_REPOSITORY_URL}"
log_info "API domain: ${API_DOMAIN}"
log_info "Argo CD domain: ${ARGOCD_DOMAIN}"
log_info "AWS Region: ${AWS_REGION}"

# Extract root domain (e.g., api.recipemanager.link -> recipemanager.link)
ROOT_DOMAIN=$(echo "${API_DOMAIN}" | rev | cut -d. -f1,2 | rev)
log_info "Root Domain: ${ROOT_DOMAIN}"
# Query Route53 for the zone ID
log_info "Looking up Route53 hosted zone ID for domain: ${ROOT_DOMAIN}"
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROOT_DOMAIN}" \
  --query "HostedZones[?Name=='${ROOT_DOMAIN}.'].Id" \
  --output text | sed 's|/hostedzone/||')
if [[ -z "${ZONE_ID}" ]]; then
  log_error "Could not get Zone ID for ${ROOT_DOMAIN}. Check if the Hosted Zone exists."
  exit 1
fi
log_info "Hosted Zone ID: ${ZONE_ID}"

# Step 1: Delete Kubernetes resources (required to remove ALB created by Ingress)
log_step "Step 1/6 : Deleting Kubernetes resources..."

# Configure kubectl, delete Argo CD-managed resources and wait for the Load Balancer Controller
# to clean up AWS resources (ALB, Target Groups, Security Groups).
if aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" 2>/dev/null; then
  # Disable auto-sync on the root Application to prevent Argo CD from re-creating
  # child Applications while we are deleting them.
  log_info "Disabling Argo CD auto-sync on root Application..."
  kubectl patch application root -n argocd \
    --type merge \
    -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || log_warn "Could not patch root Application (may not exist)"

  # Delete all child Applications (everything except root). The resources-finalizer on
  # each Application cascades to all managed resources (Deployment, Service, Ingress, etc.),
  # which causes the Load Balancer Controller to delete ALBs and ExternalDNS to delete
  # Route53 DNS records. The root Application is left for Terraform to clean up (Step 2).
  log_info "Deleting Argo CD child Applications (cascade)..."
  kubectl get applications -n argocd -o name 2>/dev/null \
    | grep -v '/root$' \
    | xargs -r kubectl delete -n argocd --wait --timeout=300s \
    || log_warn "Could not delete Argo CD child Applications (may not exist)"

  # Delete the Argo CD Ingress to trigger ALB cleanup by the Load Balancer Controller.
  # The Argo CD Ingress is managed by Helm (not by an Argo CD Application), so it is
  # not deleted when we delete child Applications above. We must delete it now while
  # the LBC is still running, otherwise the Argo CD ALB is orphaned and blocks VPC
  # deletion (the ALB holds ENIs in public subnets and references the ACM certificate
  # for argocd.recipemanager.link).
  log_info "Deleting Argo CD Ingress..."
  kubectl delete ingress --all -n argocd --timeout=60s 2>/dev/null || log_warn "Could not delete Argo CD Ingress (may not exist)"

  log_info "Waiting for AWS Load Balancer Controller to clean up AWS resources..."
  log_info "Checking for resources tagged with 'elbv2.k8s.aws/cluster: ${CLUSTER_NAME}'..."

  WAIT_TIMEOUT=400
  START_TIME=$(date +%s)

  while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [[ $ELAPSED -gt $WAIT_TIMEOUT ]]; then
      log_warn "Timeout ($WAIT_TIMEOUT seconds) waiting for AWS resources cleanup. Proceeding anyway..."
      break
    fi

    # Check for Load Balancers, Target Groups, and Security Groups managed by the Load Balancer Controller
    REMAINING_ALB_RESOURCES=$(aws resourcegroupstaggingapi get-resources \
      --region "${AWS_REGION}" \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
      --resource-type-filters "elasticloadbalancing:loadbalancer" "elasticloadbalancing:targetgroup" "ec2:security-group" \
      --query 'ResourceTagMappingList[*].ResourceARN' \
      --output text)

    # Check for DNS A records
    # There are also TXT records created by ExternalDNS for ownership tracking, but we only check for the A records which point to the ALB
    REMAINING_API_DNS=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "${ZONE_ID}" \
      --query "ResourceRecordSets[?Name=='${API_DOMAIN}.' && Type=='A'].Name" \
      --output text)
    REMAINING_ARGOCD_DNS=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "${ZONE_ID}" \
      --query "ResourceRecordSets[?Name=='${ARGOCD_DOMAIN}.' && Type=='A'].Name" \
      --output text)
    REMAINING_DNS_RECORD="${REMAINING_API_DNS}${REMAINING_ARGOCD_DNS}"

    if [[ -z "${REMAINING_ALB_RESOURCES}" && -z "${REMAINING_DNS_RECORD}" ]]; then
      log_info "All Load Balancer resources and DNS records have been successfully deleted."
      break
    fi

    if [[ -n "${REMAINING_API_DNS}" ]]; then
      log_info "DNS A Record for ${API_DOMAIN} still exists..."
    fi
    if [[ -n "${REMAINING_ARGOCD_DNS}" ]]; then
      log_info "DNS A Record for ${ARGOCD_DOMAIN} still exists..."
    fi
    if [[ -n "${REMAINING_ALB_RESOURCES}" ]]; then
      log_info "Load Balancer resources still remaining..."
    fi

    log_info "Checking again in 10s (Elapsed: ${ELAPSED}s)"
    sleep 10
  done
else
  log_error "Could not connect to EKS cluster"
  log_error "Make sure the cluster is up and you have the correct AWS credentials configured"
  log_error "Then run this script again"
  exit 1
fi

# Step 2: Delete Argo CD root Application (App of Apps)
log_step "Step 2/6 : Deleting Argo CD root Application (App of Apps)..."
terraform destroy -target=module.argocd_apps -auto-approve

# Wait for Karpenter nodes to be terminated before deleting the Karpenter controller in Step 3.
# Deleting the controller while EC2 instances are still running could leave them orphaned
# (no controller to terminate them), causing them to keep running indefinitely, incurring costs.
log_info "Waiting for Karpenter-provisioned EC2 instances to terminate..."
WAIT_TIMEOUT=400
START_TIME=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  if [[ $ELAPSED -gt $WAIT_TIMEOUT ]]; then
    log_warn "Timeout ($WAIT_TIMEOUT seconds) waiting for Karpenter nodes to terminate. Proceeding anyway..."
    break
  fi

  # Check for EC2 instances with Karpenter tags
  KARPENTER_INSTANCES=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

  if [[ -z "${KARPENTER_INSTANCES}" ]]; then
    log_info "All Karpenter-provisioned instances have been terminated."
    break
  fi

  log_info "Karpenter instances still terminating: ${KARPENTER_INSTANCES}"
  log_info "Checking again in 10s (Elapsed: ${ELAPSED}s)"
  sleep 10
done

# Step 4: Delete Kubernetes controllers (Load Balancer Controller, ExternalDNS, External Secrets Operator, Karpenter) and Argo CD Helm charts
log_step "Step 3/6 : Deleting Kubernetes controllers (Load Balancer Controller, ExternalDNS, External Secrets Operator, Karpenter) and Argo CD Helm charts..."

# Download Helm charts locally to avoid network timeouts during Terraform destroy
download_helm_charts

# Retry logic for network timeouts when downloading Helm charts
retry_with_backoff 3 "Delete Kubernetes controllers and Argo CD" \
  terraform destroy \
  -target=module.lb_controller \
  -target=module.external_dns \
  -target=module.external_secrets \
  -target=module.karpenter_controller \
  -target=module.argocd \
  -auto-approve

# Step 5: Delete all remaining resources
log_step "Step 4/6 : Deleting all remaining resources (VPC, EKS, RDS, ECR, Pod Identity, ACM Certificate, App Secrets, GitHub Actions OIDC role)..."
log_info "This may take 15-20 minutes..."

# The VPC CNI plugin (aws-node) leaves behind ENIs in Karpenter node subnets that block
# Terraform from deleting the node security group and private_nodes subnets with a
# DependencyViolation error:
#
#   module.vpc.aws_subnet.private_nodes[2]: Still destroying... [id=subnet-047445e4679d13225, 10m10s elapsed]
#   module.eks.aws_security_group.node: Still destroying... [id=sg-002256ad7ce908bc7, 10m30s elapsed]
#   │ Error: deleting EC2 Subnet (subnet-0eb3dfb352a9a3fd6): operation error EC2: DeleteSubnet, https response error StatusCode: 400, RequestID: 96639fb7-f5c4-4f24-bd10-34147a3bd29b, api error DependencyViolation: The subnet 'subnet-0eb3dfb352a9a3fd6' has dependencies and cannot be deleted.
#   │ Error: deleting Security Group (sg-0a92c40198639dbf3): operation error EC2: DeleteSecurityGroup, https response error StatusCode: 400, RequestID: 48902171-2278-4a1e-af1d-7b358c76a262, api error DependencyViolation: resource sg-0a92c40198639dbf3 has a dependent object
#
# There are two windows when these ENIs can appear:
#
#   1. Before terraform destroy: stale ENIs from already-terminated Karpenter instances.
#   2. During terraform destroy: ENIs held by aws-node on *managed node group* instances
#      are "in-use" when the pre-destroy cleanup runs. They transition to "available" when
#      EKS terminates the managed node group — at which point Terraform is already blocked.
#
# Both cases are handled by running ENI cleanup before each terraform destroy attempt.
# On the first failure, newly-released ENIs are deleted and terraform destroy is retried.
KARPENTER_SUBNET_IDS=$(aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query 'Subnets[*].SubnetId' \
  --output text | tr '\t' ',')

MAX_ATTEMPTS=2
for attempt in $(seq 1 ${MAX_ATTEMPTS}); do
  if [[ -n "${KARPENTER_SUBNET_IDS}" ]]; then
    log_info "Cleaning up orphaned ENIs in Karpenter node subnets (attempt ${attempt}/${MAX_ATTEMPTS})..."
    # Only delete ENIs in "available" status
    AVAILABLE_ENIS=$(aws ec2 describe-network-interfaces \
      --region "${AWS_REGION}" \
      --filters "Name=subnet-id,Values=${KARPENTER_SUBNET_IDS}" "Name=status,Values=available" \
      --query 'NetworkInterfaces[*].NetworkInterfaceId' \
      --output text)
    if [[ -n "${AVAILABLE_ENIS}" ]]; then
      for ENI_ID in ${AVAILABLE_ENIS}; do
        log_info "Deleting orphaned ENI: ${ENI_ID}"
        aws ec2 delete-network-interface \
          --region "${AWS_REGION}" \
          --network-interface-id "${ENI_ID}" || log_warn "Could not delete ENI ${ENI_ID}"
      done
    else
      log_info "No orphaned ENIs found."
    fi
  fi

  if terraform destroy \
    -target=module.vpc \
    -target=module.eks \
    -target=module.rds \
    -target=module.ecr \
    -target=module.pod_identity \
    -target=module.acm_certificates \
    -target=module.app_secrets \
    -target=module.github_actions_oidc_role_server \
    -auto-approve; then
    break
  fi

  if [[ ${attempt} -lt ${MAX_ATTEMPTS} ]]; then
    log_warn "terraform destroy failed (attempt ${attempt}/${MAX_ATTEMPTS}). ENIs released during EKS deletion will be cleaned up on next attempt..."
  else
    log_error "terraform destroy failed after ${MAX_ATTEMPTS} attempts."
    exit 1
  fi
done

log_info "Remaining resources (VPC, EKS, RDS, ECR...) deleted successfully"

# Step 6: Cleanup local Docker images
log_step "Step 5/6 : Cleaning up local Docker images..."

# Check if Docker is available
if command -v docker &>/dev/null && docker info >/dev/null 2>&1; then
  # Remove <account-id>.dkr.ecr.us-east-1.amazonaws.com/recipe-manager-server-dev:2026-01-29-12h56m33s
  log_info "Removing Docker images tagged with ECR repository URL..."
  ECR_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "${ECR_REPOSITORY_URL}" || true)
  if [[ -n "${ECR_IMAGES}" ]]; then
    echo "${ECR_IMAGES}" | xargs -r docker rmi -f 2>/dev/null || log_warn "Some ECR images could not be removed"
    log_info "ECR-tagged images removed."
  else
    log_info "No ECR-tagged images found."
  fi

  # Remove recipe-manager-server:03c6255
  log_info "Removing recipe-manager-server images with Git commit SHA tags..."
  # Match images with short git commit SHA (7 hexadecimal characters)
  SERVER_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "recipe-manager-server:[0-9a-f]{7}$" || true)
  if [[ -n "${SERVER_IMAGES}" ]]; then
    echo "${SERVER_IMAGES}" | xargs -r docker rmi -f 2>/dev/null || log_warn "Some server images could not be removed"
    log_info "Server images removed."
  else
    log_info "No recipe-manager-server images with Git commit SHA tags found."
  fi
else
  log_warn "Docker is not available. Skipping Docker image cleanup."
fi

# Step 7: Cleanup ~/.kube/config
log_step "Step 6/6 : Removing kubeconfig context, cluster and user entries..."
CLUSTER_ARN="arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
kubectl config delete-context "${CLUSTER_ARN}" || true
kubectl config delete-cluster "${CLUSTER_ARN}" || true
kubectl config delete-user "${CLUSTER_ARN}" || true
log_info "Removed kubeconfig entries for ${CLUSTER_ARN} (if present)."

# Display summary
echo ""
echo "=========================================="
echo "Infrastructure Deletion Complete!"
echo "=========================================="
echo ""

log_info "All AWS infrastructure for the '${ENVIRONMENT}' environment has been deleted."
echo ""
