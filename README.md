# Recipe Manager

_A Full Stack app built with Node, React, PostgreSQL, REST API, AWS, Kubernetes (EKS), Argo CD and GitHub Actions_

Live site: https://recipemanager.link

## Technologies used

### Tools

- Hosted on AWS.
- Infrastructure as Code with Terraform
- CI/CD with GitHub Actions and Argo CD.
- Local development with Docker Compose.
- 100% TypeScript, zero JavaScript.

### Frontend

- React single-page application.
- State management with [Valtio](https://github.com/pmndrs/valtio).
- Routing with [React Router](https://reactrouter.com/en/main) 6.
- UI design with [Chakra UI](https://chakra-ui.com).

### Backend

- Node.js server built with Express.js.
- Database with PostgreSQL.
- Data validation with [zod](https://github.com/colinhacks/zod).
- Testing
  - Unit tests for functions with Jest.
  - Unit tests for route handlers and middleware with [node-mocks-http](https://github.com/howardabrams/node-mocks-http).
  - Integration tests for routes with [supertest](https://github.com/visionmedia/supertest).

### AWS

- Frontend deployed to S3 and CloudFront automatically using GitHub Actions.
- Server deployed to EKS using GitHub Actions and Argo CD.
- RDS PostgreSQL database.
- ECR for Docker image storage.
- Secrets Manager for application secrets (RDS master password, JWT secret, email credentials).

### Kubernetes (EKS)

- Managed Node Group that runs CoreDNS, Load Balancer Controller, Karpenter controller, Argo CD, ExternalDNS and External Secrets Operator.
- Ingress with AWS Load Balancer Controller.
- Karpenter for automatic provisioning of nodes based on workload.
- Argo CD for GitOps-based continuous deployment (App of Apps pattern).
- ExternalDNS for automatic Route53 DNS record management.
- External Secrets Operator for syncing secrets from AWS Secrets Manager to Kubernetes Secrets.
- Pod Identity.
- Kustomize for managing Kubernetes manifests.

## Features

- Authentication: register, login, validate email, recover password.
- Settings: change the user's name, email and password. Delete the user account.
- Recipe: publish, edit and delete recipes.

## Local development

The application is available at:

- Web (React): http://localhost:3000
- Server (API): http://localhost:5000
- Database: localhost:5432

To run the app locally, do:

```shell
cp .env.local .env
# (Optional) Edit .env to adjust values

# Start all services
docker compose up --build

# (Optional) Seed the database with users and recipes
./scripts/local-development/seed-database.sh

# View service status
docker compose ps

# Stop everything, but keep the database data
docker compose down
# Stop everything and discard the database data
docker compose down --volumes
```

To run only a single service locally do:

```shell
cd server # Or cd web
npm install
npm run dev
```

### Local database

The local PostgreSQL database is created automatically when you run `docker compose up --build`. You can interact with it from within the Docker container.

```shell
# Connect to database from within the Docker container
docker compose exec db psql -U postgres -d recipemanager

# Backup database
docker compose exec db pg_dump -U postgres recipemanager > backup.sql

# Restore database
docker compose exec -T db psql -U postgres -d recipemanager < backup.sql
```

The database port is exposed to `localhost:5432` on the host machine. This allows you to connect to the database using a client from your machine.

```shell
# Connect to database from your host machine
psql -h localhost -p 5432 -U postgres -d recipemanager
```

You will be prompted for the password, which is defined in your `.env` file.

### Seed the local database

Once the local database container is running, you can automatically fill it with users and recipes using the provided script:

```shell
./scripts/local-development/seed-database.sh
```

This script will:

1. Create two test users.
2. Seed the database with sample recipe data.

Alternatively, you can run similar steps manually:

- `curl http://localhost:5000/api/auth/register -H "Content-Type: application/json" -d '{"name":"Albert", "email":"a@a.com", "password":"123456"}'`
- `curl http://localhost:5000/api/auth/register -H "Content-Type: application/json" -d '{"name":"Blanca", "email":"b@b.com", "password":"123456"}'`
- `docker compose exec -T db psql -U postgres -d recipemanager < server/database-seed.sql`

## Database

Database schema changes are managed using [node-pg-migrate](https://github.com/salsita/node-pg-migrate).
Migrations run automatically when the server starts.
Migrations are stored in `server/migrations/` as SQL files.

### Creating a new migration

```shell
cd server
npm run migrate:create -- my-migration-name
```

This creates a new SQL file in `server/migrations/` with a timestamp prefix. Edit the file to add your schema changes:

```sql
-- Up Migration
ALTER TABLE recipe ADD COLUMN description TEXT;

---- Down Migration
ALTER TABLE recipe DROP COLUMN description;
```

### Running migrations manually

Migrations run automatically on server startup, but you can also run them manually:

```shell
cd server

# Run the next pending migration
npm run migrate:up

# Rollback the last migration
npm run migrate:down
```

## Email account setup

Sending emails requires creating an account at https://ethereal.email. Click the 'Create Ethereal Account' button and copy-paste the user and password to the `.env` file environment variables `EMAIL_USER` and `EMAIL_PASSWORD`.

You can view the emails at https://ethereal.email/messages. URLs to view each email sent are also logged at the server console.

## Git pre-commit hook

To check formatting and validate code on every commit, set up the Git pre-commit hook:

```shell
cp pre-commit .git/hooks
```

Note that the checks do not abort the commit (it's very annoying), they only inform you of any issues found. It's your responsibility to fix them and amend the commit.

The checks performed are:

- Prettier for code formatting.
- TypeScript compiler (tsc) for type checking.
- ESLint for linting.
- Terraform fmt and validate.
- TFLint for Terraform linting, with the AWS plugin.
- ShellCheck to lint shell scripts.
- shfmt for shell script formatting.
  - Files are formatted with the options `-i 2 -ci -bn`, following [Google's shell style](https://google.github.io/styleguide/shellguide.html#formatting). Run `shfmt -i 2 -ci -bn -w <file> <directory>` to format a file and/or directory.
- YAMLLint for YAML file linting.
- Actionlint for GitHub Actions workflow syntax validation.

## Deploy infrastructure with Terraform

### Bootstrap: Create S3 buckets for Terraform state

Before deploying any infrastructure, you need to create the S3 buckets that Terraform will use to store its state.
Use the provided script to do this:

```shell
./scripts/bootstrap/create-state-bucket.sh dev  # Or prod
```

### Bootstrap: GitHub Actions OIDC provider

Before deploying any web or server environment, you must create the GitHub Actions OIDC identity provider once per AWS account. This is a one-time step that enables GitHub Actions workflows to authenticate with AWS without long-lived credentials.

```shell
cd terraform/bootstrap/environments/all
terraform init
terraform apply
```

### Web (Frontend)

To create the S3 bucket and CloudFront distribution that the web app will be deployed to do the following:

```shell
cd terraform/web/environments/dev # Or prod
# Edit terraform.tfvars with your values if needed

# Initialize using the generated backend.config file created by scripts/bootstrap/create-state-bucket.sh
terraform init -backend-config="backend.config"
```

### Server (API)

#### 1. Create AWS Infrastructure

Edit the `terraform/server/environments/dev/terraform.tfvars` or `prod/terraform.tfvars` file to adjust values to your desire before running the script. If you edit the `terraform.tfvars`, you should run the synchronization script to update the Kubernetes manifests with the new values:

```shell
./scripts/server/sync-k8s-with-tfvars.sh dev # Or prod
```

Create the AWS infrastructure (VPC, EKS, RDS, ECR, etc.):

```shell
./scripts/server/create-aws-infrastructure.sh dev  # Or prod
```

This script will:

- Initialize Terraform
- Create VPC, EKS cluster, RDS database, ECR repository, Pod Identity, ACM certificate for the API endpoint and application secrets (JWT, email credentials)
- Install Load Balancer Controller, ExternalDNS, External Secrets Operator, Karpenter and Argo CD using Helm
- Create the Argo CD root Application (App of Apps)
- Create Karpenter NodePool and EC2NodeClass
- Display next steps

This process takes approximately 20-30 minutes.

#### 2. Build and Push Docker Image

After the AWS infrastructure is created, build and push the Docker image to ECR:

```shell
./scripts/server/build-push-image-ecr.sh dev  # Or prod
```

This script will:

- Build the Docker image with a git commit SHA tag
- Log in to ECR and push the image
- Output the IMAGE_TAG to use for deployment

#### 3. Deploy Server Application to EKS

Deploy the server application to the EKS cluster:

```shell
./scripts/server/deploy-server-eks.sh dev <image_tag>  # Use the IMAGE_TAG from build-push-image-ecr.sh output
```

For example:

```shell
./scripts/server/deploy-server-eks.sh dev abc1234
```

This script will:

- Configure kubectl to connect to the EKS cluster
- Fetch configuration from Terraform outputs, terraform.tfvars file, AWS Secrets Manager, etc.
- Process Kubernetes manifests using Kustomize and replace placeholders
- Apply the manifests to deploy the server to EKS and wait for the deployment to complete
- When the Ingress is created, the Load Balancer Controller provisions an Application Load Balancer and ExternalDNS creates the Route53 A record for the API endpoint pointing to the ALB.

#### 4. Delete AWS Infrastructure

To delete all AWS infrastructure:

```shell
./scripts/server/delete-aws-infrastructure.sh dev  # Or prod
```

This script will:

- Prompt for confirmation
- Delete Kubernetes resources
- Delete AWS infrastructure (VPC, EKS, RDS, ECR, etc.) in the correct order

**Warning:** This will permanently delete all infrastructure resources, including the ECR images!

## CI/CD Pipeline

The project uses GitHub Actions workflows split into two types: CI and CD.

### CI workflows (`ci-*.yml`)

Run on `push` to main and on `pull_request` targeting main. They check formatting (Prettier, shfmt, terraform fmt), perform linting (ESLint, ShellCheck, YAMLLint, Actionlint, TFLint, KubeLinter, Hadolint), type checking (tsc), run tests, configuration and security scans (npm audit, Trivy, Checkov), etc.

### CD workflows (`cd-*.yml`)

Run only on `push` to main (i.e., when a PR is merged). They deploy new code to AWS.

| Workflow                          | Trigger paths | Jobs                                                         |
| --------------------------------- | ------------- | ------------------------------------------------------------ |
| `.github/workflows/cd-server.yml` | `server/**`   | Build & push server Docker image to ECR and update image tag |
| `.github/workflows/cd-web.yml`    | `web/**`      | Deploy React app to S3 and CloudFront                        |

These workflows use environment variables that you need to set up in GitHub for the OIDC authentication and deployment to work.
At GitHub, go to Settings → Environments and create two environments named "dev" and "prod".
On that page, click the environment and add the following environment variables (not secrets) for each environment.

Production deployments are gated by GitHub environment protection rules (required reviewers). Once the environment is created, configure the required reviewers at Settings → Environments → prod → Required reviewers.

#### `cd-web.yml`

The CD web workflow builds the React app and deploys it to S3 and CloudFront using the AWS CLI.

Environment variables for `.github/workflows/cd-web.yml`:

| Variable                               | Value                                                                                 |
| -------------------------------------- | ------------------------------------------------------------------------------------- |
| `AWS_REGION`                           | `us-east-1`                                                                           |
| `AWS_GITHUB_ACTIONS_OIDC_ROLE_ARN_WEB` | `terraform output web_github_actions_oidc_role_arn`                                   |
| `WEB_S3_BUCKET`                        | `terraform output website_s3_bucket_name`                                             |
| `WEB_CLOUDFRONT_DISTRIBUTION_ID`       | `terraform output website_cloudfront_distribution_id`                                 |
| `VITE_API_BASE_URL`                    | `https://api.recipemanager.link/api` (dev) or `https://api.recipeapp.link/api` (prod) |

Run `terraform output` in `terraform/web/environments/[env]`.
If you changed any value in `terraform.tfvars`, then use it.

#### `cd-server.yml`

The CD server workflow builds the Docker image, pushes it to ECR, and commits an updated image tag to `kubernetes/server/overlays/[env]/kustomization.yaml`.
Argo CD detects the commit and automatically syncs the changes to the cluster.

Environment variables for `.github/workflows/cd-server.yml`:

| Variable                                  | Value                                                  |
| ----------------------------------------- | ------------------------------------------------------ |
| `AWS_REGION`                              | `us-east-1`                                            |
| `AWS_GITHUB_ACTIONS_OIDC_ROLE_ARN_SERVER` | `terraform output server_github_actions_oidc_role_arn` |
| `ECR_REPOSITORY_URL`                      | `terraform output ecr_repository_url`                  |

Run `terraform output` in `terraform/server/environments/[env]`.

## Manually deploy the React web app to AWS S3 and CloudFront

This is done automatically using GitHub Actions ([see the `cd-web.yml` workflow](#cd-webyml)), but you can also do it manually:

```shell
cd web
npm run build
aws s3 sync build s3://<s3-bucket-name> --delete
aws cloudfront create-invalidation --distribution-id <distribution-id> --paths '/*'
```
