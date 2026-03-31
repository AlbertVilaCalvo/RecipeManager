#!/bin/bash
#
# Syncs (copies) configuration values from terraform.tfvars to Kubernetes manifests
#
# Usage:
#   ./scripts/server/sync-k8s-with-tfvars.sh <environment>
#
# Arguments:
#   environment - The deployment environment (dev or prod)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

ENVIRONMENT="${1:-}"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBERNETES_DIR="${PROJECT_ROOT}/kubernetes/server"
ARGOCD_APPS_DIR="${PROJECT_ROOT}/kubernetes/argocd-apps/${ENVIRONMENT}"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform/server/environments/${ENVIRONMENT}"

if [[ -z "${ENVIRONMENT}" ]]; then
  log_error "Environment is required."
  log_error "Usage: ./scripts/server/sync-k8s-with-tfvars.sh <environment>"
  log_error "Example: ./scripts/server/sync-k8s-with-tfvars.sh dev"
  exit 1
fi

validate_environment "${ENVIRONMENT}"

validate_directory_exists "${TERRAFORM_DIR}"
validate_directory_exists "${KUBERNETES_DIR}"
validate_directory_exists "${ARGOCD_APPS_DIR}"

log_info "Syncing Kubernetes manifests for environment: ${ENVIRONMENT}"

API_DOMAIN=$(get_tfvars_value "api_domain")
WEB_DOMAIN=$(get_tfvars_value "web_domain")
AWS_REGION=$(get_tfvars_value "aws_region")
RDS_DATABASE_NAME=$(get_tfvars_value "database_name")
RDS_USERNAME=$(get_tfvars_value "master_username")
GIT_REPO_URL=$(get_tfvars_value "git_repo_url")
GIT_REVISION=$(get_tfvars_value "git_revision")

CORS_ORIGINS="https://${WEB_DOMAIN},https://www.${WEB_DOMAIN}"

BASE_DIR="${KUBERNETES_DIR}/base"
OVERLAY_DIR="${KUBERNETES_DIR}/overlays/${ENVIRONMENT}"

log_info "Updating manifests in ${OVERLAY_DIR} and ${BASE_DIR}..."

# Update ingress_patch.yaml
sed -i.bak \
  -e "s|external-dns.alpha.kubernetes.io/hostname: .*|external-dns.alpha.kubernetes.io/hostname: ${API_DOMAIN}|g" \
  "${OVERLAY_DIR}/ingress_patch.yaml"
sed -i.bak \
  -e "s|- host: .*|- host: ${API_DOMAIN}|g" \
  "${OVERLAY_DIR}/ingress_patch.yaml"

# Update configmap_patch.yaml
sed -i.bak \
  -e "s|CORS_ORIGINS: .*|CORS_ORIGINS: '${CORS_ORIGINS}'|g" \
  "${OVERLAY_DIR}/configmap_patch.yaml"
sed -i.bak \
  -e "s|DB_NAME: .*|DB_NAME: '${RDS_DATABASE_NAME}'|g" \
  "${OVERLAY_DIR}/configmap_patch.yaml"

# Update base configmap.yaml
sed -i.bak \
  -e "s|DB_USER: .*|DB_USER: '${RDS_USERNAME}'|g" \
  "${BASE_DIR}/configmap.yaml"

# Update base secret-store.yaml
sed -i.bak \
  -e "s|region: .*|region: ${AWS_REGION}|g" \
  "${BASE_DIR}/secret-store.yaml"

# Update Argo CD Application manifests (repoURL and targetRevision)
sed -i.bak \
  -e "s|repoURL: .*|repoURL: ${GIT_REPO_URL}|g" \
  -e "s|targetRevision: .*|targetRevision: ${GIT_REVISION}|g" \
  "${ARGOCD_APPS_DIR}/server-app.yaml"

sed -i.bak \
  -e "s|repoURL: .*|repoURL: ${GIT_REPO_URL}|g" \
  -e "s|targetRevision: .*|targetRevision: ${GIT_REVISION}|g" \
  "${ARGOCD_APPS_DIR}/karpenter-app.yaml"

# Cleanup sed backups
rm -f "${OVERLAY_DIR}/ingress_patch.yaml.bak" \
  "${OVERLAY_DIR}/configmap_patch.yaml.bak" \
  "${BASE_DIR}/configmap.yaml.bak" \
  "${BASE_DIR}/secret-store.yaml.bak" \
  "${ARGOCD_APPS_DIR}"/server-app.yaml.bak \
  "${ARGOCD_APPS_DIR}"/karpenter-app.yaml.bak

log_info "Manifest synchronization complete."
