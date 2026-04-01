#!/bin/bash
#
# Common utilities for Recipe Manager shell scripts
#
# This file provides shared functions and variables used across multiple scripts
# in the Recipe Manager project. It should be sourced, not executed directly.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=/dev/null
#   source "${SCRIPT_DIR}/../lib/common.sh"
#
# Available utilities:
#   - Color variables: RED, GREEN, YELLOW, BLUE, NC
#   - Logging functions: log_info, log_warn, log_error, log_step
#   - Terraform helpers: get_terraform_output, get_tfvars_value
#   - Validation helpers: validate_environment, validate_command_exists, validate_directory_exists, validate_file_exists
#   - Retry logic: retry_with_backoff
#   - Helm chart helpers: download_helm_charts
#   - Constants: SECTION_SEP

set -euo pipefail

# ============================================================================
# Color Definitions
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Constants
# ============================================================================

# Section separator for decorative output (exported for use in scripts)
export SECTION_SEP="============================================================================"

# ============================================================================
# Logging Functions
# ============================================================================

# Print an informational message in green
# Arguments:
#   $1 - Message to print
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

# Print a warning message in yellow
# Arguments:
#   $1 - Message to print
log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

# Print an error message in red
# Arguments:
#   $1 - Message to print
log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Print a step message in blue
# Arguments:
#   $1 - Message to print
log_step() {
  echo -e "\n${BLUE}[STEP]${NC} $1"
}

# ============================================================================
# Terraform Helper Functions
# ============================================================================

# Get a Terraform output value
# Arguments:
#   $1 - Output name
# Returns:
#   The raw output value
# Note:
#   Requires TERRAFORM_DIR to be set in the calling script
get_terraform_output() {
  local output_name="$1"
  local value

  # Capture output. terraform output prints errors to stderr, which remains visible.
  if ! value=$(terraform -chdir="${TERRAFORM_DIR}" output -raw "${output_name}"); then
    log_error "Value for '${output_name}' not found in ${TERRAFORM_DIR}" >&2
    return 1
  fi

  if [[ -z "${value}" ]]; then
    log_error "Terraform output '${output_name}' is empty." >&2
    return 1
  fi

  echo "${value}"
}

# Get a value from terraform.tfvars file
# Arguments:
#   $1 - Key name
# Returns:
#   The value (extracted from between quotes)
# Note:
#   Requires TERRAFORM_DIR to be set in the calling script
get_tfvars_value() {
  local key="$1"
  local tfvars_file="${TERRAFORM_DIR}/terraform.tfvars"

  if [[ ! -f "${tfvars_file}" ]]; then
    log_error "terraform.tfvars not found at ${tfvars_file}"
    return 1
  fi

  # Extract value between quotes, handling optional spaces
  local value
  value=$(grep "^\s*${key}\s*=" "${tfvars_file}" | head -n1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/' || true)

  if [[ -z "${value}" ]]; then
    # Print to stderr so it's printed even when the function call is part of an assignment
    log_error "Value for '${key}' not found in ${tfvars_file}" >&2
    return 1
  fi

  echo "${value}"
}

# ============================================================================
# Validation Helper Functions
# ============================================================================

# Validate that the environment is either 'dev' or 'prod'
# Arguments:
#   $1 - Environment name
# Returns:
#   1 if environment is invalid
validate_environment() {
  local environment="$1"
  if [[ "${environment}" != "dev" && "${environment}" != "prod" ]]; then
    log_error "Invalid environment: ${environment}. Must be 'dev' or 'prod'."
    return 1
  fi
}

# Validate that a command exists and is executable
# Arguments:
#   $1 - Command name
# Returns:
#   1 if command not found
validate_command_exists() {
  local command_name="$1"
  if ! command -v "${command_name}" &>/dev/null; then
    log_error "${command_name} is not installed. Please install it and try again."
    return 1
  fi
}

# Validate that a directory exists
# Arguments:
#   $1 - Directory path
#   $2 - Optional custom error message
# Returns:
#   1 if directory not found
validate_directory_exists() {
  local dir_path="$1"
  local custom_message="${2:-}"

  if [[ ! -d "${dir_path}" ]]; then
    if [[ -n "${custom_message}" ]]; then
      log_error "${custom_message}"
    else
      log_error "Directory not found: ${dir_path}"
    fi
    return 1
  fi
}

# Validate that a file exists
# Arguments:
#   $1 - File path
#   $2 - Optional custom error message
# Returns:
#   1 if file not found
validate_file_exists() {
  local file_path="$1"
  local custom_message="${2:-}"

  if [[ ! -f "${file_path}" ]]; then
    if [[ -n "${custom_message}" ]]; then
      log_error "${custom_message}"
    else
      log_error "File not found: ${file_path}"
    fi
    return 1
  fi
}

# ============================================================================
# Retry Logic
# ============================================================================

# Retry a command with a fixed 10-second delay
# Arguments:
#   $1 - Maximum number of retries
#   $2 - Operation name
#   $3+ - Command to execute (all remaining arguments)
# Returns:
#   0 on success, exits with 1 on failure after max retries
# Example:
#   retry_with_backoff 3 "Terraform apply" terraform apply -auto-approve
retry_with_backoff() {
  local max_retries="$1"
  local operation_name="$2"
  shift 2
  local command=("$@")

  local retry_count=0
  while [ $retry_count -lt "$max_retries" ]; do
    if "${command[@]}"; then
      log_info "${operation_name} succeeded"
      return 0
    else
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt "$max_retries" ]; then
        log_warn "${operation_name} failed (attempt $retry_count/$max_retries). Retrying in 10 seconds..."
        sleep 10
      else
        log_error "${operation_name} failed after $max_retries attempts"
        return 1
      fi
    fi
  done
}

# ============================================================================
# Helm Chart Helpers
# ============================================================================

# Download Helm charts locally to avoid network timeouts during Terraform operations
# Note:
#   Requires TERRAFORM_DIR to be set in the calling script
# We download charts locally to avoid this error during Terraform apply/destroy:
# │ Error: Error locating chart
# │
# │ with module.lb_controller.helm_release.aws_load_balancer_controller,
# │ on ../../modules/lb-controller/lb-controller.tf line 6, in resource "helm_release" "aws_load_balancer_controller":
# │ 6: resource "helm_release" "aws_load_balancer_controller" {
# │
# │ Unable to locate chart aws-load-balancer-controller: Get "https://aws.github.io/eks-charts/aws-load-balancer-controller-1.17.1.tgz": read tcp 192.168.1.59:51924->185.199.110.153:443: read: operation timed out
# Charts are downloaded to the environment-specific .charts/ directory.
# We do not download the Karpenter and Argo CD charts because they use oci://,
# and the download is reliable.
download_helm_charts() {
  local charts_dir="${TERRAFORM_DIR}/.charts"

  local lb_version
  local dns_version

  lb_version="$(get_tfvars_value "lb_controller_chart_version")"
  dns_version="$(get_tfvars_value "external_dns_chart_version")"

  if [[ -z "${lb_version}" || -z "${dns_version}" ]]; then
    log_error "Could not read chart versions from terraform.tfvars"
    return 1
  fi

  mkdir -p "${charts_dir}"

  log_info "Downloading Helm charts directly via curl (IPv4) to bypass Helm repo/IPv6 timeouts..."

  if [[ ! -f "${charts_dir}/aws-load-balancer-controller-${lb_version}.tgz" ]]; then
    log_info "Downloading aws-load-balancer-controller-${lb_version}.tgz"
    if ! curl -4 -fsSLo "${charts_dir}/aws-load-balancer-controller-${lb_version}.tgz" "https://aws.github.io/eks-charts/aws-load-balancer-controller-${lb_version}.tgz"; then
      log_warn "Failed to download aws-load-balancer-controller-${lb_version}.tgz. Terraform will download it from the Helm repository."
      rm -f "${charts_dir}/aws-load-balancer-controller-${lb_version}.tgz"
    fi
  else
    log_info "aws-load-balancer-controller-${lb_version}.tgz already downloaded."
  fi

  if [[ ! -f "${charts_dir}/external-dns-${dns_version}.tgz" ]]; then
    log_info "Downloading external-dns-${dns_version}.tgz"
    if ! curl -4 -fsSLo "${charts_dir}/external-dns-${dns_version}.tgz" "https://github.com/kubernetes-sigs/external-dns/releases/download/external-dns-helm-chart-${dns_version}/external-dns-${dns_version}.tgz"; then
      log_warn "Failed to download external-dns-${dns_version}.tgz. Terraform will download it from the Helm repository."
      rm -f "${charts_dir}/external-dns-${dns_version}.tgz"
    fi
  else
    log_info "external-dns-${dns_version}.tgz already downloaded."
  fi
}
