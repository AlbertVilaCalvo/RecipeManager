locals {
  service_account_name = "external-secrets"
  namespace            = "external-secrets"
}

resource "aws_iam_role" "external_secrets" {
  name = "${var.app_name}-external-secrets-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = local.service_account_name
  role_arn        = aws_iam_role.external_secrets.arn

  tags = {
    Name = "${var.app_name}-pod-identity-association-external-secrets-${var.environment}"
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.app_name}-external-secrets-policy-${var.environment}"
  description = "IAM policy for External Secrets Operator to read secrets from AWS Secrets Manager in ${var.app_name} ${var.environment} environment"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = var.secrets_manager_secret_arns
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = var.ssm_parameter_arns
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}
