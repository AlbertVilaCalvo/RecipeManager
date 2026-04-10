# Recipe Manager

Recipe Manager is a web application that allows users to manage cooking recipes. Users can read, create, update and delete recipes.

This is a project I'm building to learn technologies like Node.js, AWS, Terraform, Kubernetes, EKS, Docker, databases, system design, software architecture, microservices, Domain-Driven Design, CI/CD, GitHub Actions, GitOps, Argo CD, observability, REST API design etc.

## Project Overview & Architecture

Recipe Manager is a full-stack web application built using React on the client and Node.js on the server, with a PostgreSQL database. The application is deployed on AWS, with infrastructure managed using Terraform. The website is deployed to S3 and CloudFront using GitHub Actions, and the server is deployed to EKS using GitHub Actions and Argo CD. The application is deployed to two different environments: dev and prod. Local development is done using Docker and Docker Compose.

The project structure is:

- `/server`: A Node.js (Express) REST API backend.
  - `/server/src/router.ts`: API endpoints definition.
- `/web`: A React single-page application frontend.
  - `/web/src/ui`: React components and pages.
- `/terraform`: Terraform code for AWS infrastructure.
  - `/terraform/bootstrap`: S3 buckets for Terraform state and GitHub Actions OIDC provider.
  - `/terraform/web`: Infrastructure for the frontend.
  - `/terraform/server`: Infrastructure for the Node.js API.
- `kubernetes`: Kubernetes manifests.
  - `kubernetes/server`: Manifests for the server. Uses Kustomize.
  - `kubernetes/argocd-apps`: Argo CD Application manifests. Uses the App of Apps pattern.
- `/scripts`: Scripts for seeding the database, deploying the AWS infrastructure, etc.
- `.github/workflows`: GitHub Actions workflows for CI/CD.
  - CI workflows (`ci-*.yml`). PR-triggered validation workflows. They check formatting (Prettier, shfmt, terraform fmt), perform linting (ESLint, ShellCheck, YAMLLint, Actionlint, TFLint, KubeLinter, Hadolint), type checking (tsc), run tests, configuration and security scans (npm audit, Trivy, Checkov), etc. Blocking checks must pass before merging.
  - CD workflows (`cd-*.yml`). Run when a PR is merged. Production deployments are gated by GitHub environment protection rules (required reviewers).
    - `cd-server.yml`: Builds the server Docker image and pushes it to ECR. Then edits the image tag in `kustomization.yaml` and commits. Argo CD detects the commit and syncs the changes to the cluster.
    - `cd-web.yml`: Builds and deploys the React web app to S3 + CloudFront.

The server follows a three-layer architecture for organizing business logic:

1. Controllers (`/server/src/**/*Controller.ts`): Handle HTTP requests and responses. They are responsible for input validation and calling services.
2. Services (`/server/src/**/*Service.ts`): Contain the core application logic and orchestrate operations.
3. Database (`/server/src/**/*Database.ts`): Encapsulate all direct database interactions using the `pg` library.

## Coding Standards & Conventions

- TypeScript: The entire codebase is written in TypeScript. Avoid JavaScript.
- Code Style: Prettier is used for formatting. Adhere to its conventions (single quotes, no semicolons, 2-space indentation and trailing commas).
- Asynchronous Code: Prefer `async/await` for asynchronous operations.

## Server Patterns

- Follow RESTful API design principles.
- Error Handling: The server endpoints return a custom `ApiError` class (`/server/src/misc/ApiError.ts`) for expected errors (e.g., "not found", "invalid input").
- Result: Database functions return a result discriminated union (see `/server/src/misc/result.ts`).
- Use Jest for unit tests.
- Use Supertest for integration tests.

## Server Infrastructure

- EKS cluster for server deployment.
- RDS PostgreSQL database.
- ECR for Docker image storage.
- Secrets Manager for application secrets (RDS master password, JWT secret, email credentials).
- EKS Kubernetes cluster includes:
  - Managed Node Group that runs CoreDNS, Load Balancer Controller, Karpenter controller, Argo CD, ExternalDNS and External Secrets Operator.
  - Ingress with AWS Load Balancer Controller.
  - Karpenter for automatic provisioning of nodes based on workload. App pods run on Karpenter provisioned nodes.
  - Argo CD for GitOps-based continuous deployment. Uses the App of Apps pattern with a root Application that points to `kubernetes/argocd-apps/{environment}/`.
  - ExternalDNS for automatic Route53 DNS record management.
  - External Secrets Operator for syncing secrets from AWS Secrets Manager to Kubernetes Secrets.
  - Pod Identity for authentication. Do not use IAM Roles for Service Accounts (IRSA).
  - Kustomize for managing Kubernetes manifests.

## Frontend Patterns

- State Management: Global state is managed with Valtio.
- API Communication: All HTTP requests to the backend are centralized in API modules (e.g., `/web/src/recipe/RecipeApi.ts`) which use a shared `httpClient.ts`.
- UI Components: The UI is built using Chakra UI. When creating new components, use Chakra components whenever possible.
- Navigation: React Router is used for client-side routing. Define routes in `/web/src/App.tsx` and use the `useNavigate` hook for navigation within components.

## Frontend Infrastructure

- React frontend is deployed to CloudFront, using a private S3 bucket as the origin.
- Deployment is done automatically using GitHub Actions (see `.github/workflows/web.yml`).

## Terraform

- Infrastructure as Code: All AWS infrastructure is defined using Terraform in the `/terraform` directory.
- Variables: Define input variables in `variables.tf` and outputs in `outputs.tf`. In general, avoid default values in variables; instead, require all variables to be explicitly set in `terraform.tfvars` files.
- Organization: Group resources by AWS service (S3, RDS, EKS, CloudFront, etc.).
- Naming: Use the following format for resource names: `${var.app_name}-<resource>-${var.environment}`.
- Tagging: All resources should include the default tags `Application` and `Environment`, but these tags should be set using the `default_tags` in the provider configuration, not in the individual resources.
- Follow Google Cloud's best practices for Terraform: https://cloud.google.com/docs/terraform/best-practices/root-modules. In particular, ensure that:
  - Don't include more than 100 resources in a single state.
  - Use separate directories for each service.
  - Split the Terraform configuration for a service into two top-level directories: a `modules` directory that contains the actual configuration for the service, and an `environments` directory that contains the root configurations for each environment.
    - Each module in the `modules` directory must contain a `required-providers.tf` file that defines the minimum required provider versions in a `required_providers` block. Avoid having a file named `main.tf` in each module, use descriptive names like `s3.tf`, `vpc.tf` or `rds.tf` instead.
    - Each `environment` directory must contain a `main.tf` file that instantiates the service modules, a `providers.tf` file that defines the provider configuration and versions, and a `backend.tf` file that defines the backend configuration.
- When defining IAM policies, prefer `jsonencode` over heredoc syntax for the `policy` and `assume_role_policy` arguments.
- When defining security groups, use `aws_vpc_security_group_egress_rule` and `aws_vpc_security_group_ingress_rule`, not the `aws_security_group_rule` resource nor the `ingress` and `egress` arguments.
- When dealing with sensitive values like passwords or database credentials, use `ephemeral` resources write-only arguments.

## Docker

- Do not use the `latest` tags for Docker images. Always specify a specific version.

## Shell scripts

- Format shell scripts with `shfmt` using the options `-i 2 -ci -bn`, like this: `shfmt -i 2 -ci -bn -w <file> <directory>`.
- Lint shell scripts with ShellCheck, using the command `shellcheck <file>`.

## YAML files

- When editing YAML files, format them with `prettier` using the command `npm run format` or `npx prettier --write <file> <directory>`.
