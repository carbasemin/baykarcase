# CI Pipeline — Design Notes

## What This Does

Every push to `main` triggers a GitHub Actions workflow that:

1. Authenticates to AWS using **OIDC** (no stored credentials).
2. Builds Docker images for the MERN backend and frontend.
3. Pushes both images to **Amazon ECR** with two tags: `latest` and the Git commit SHA.

---

## Decisions & Trade-offs

### Single branch, no PRs

This project uses a single `main` branch with direct pushes. The OIDC trust policy (in Terraform) is scoped to `ref:refs/heads/main` only, so PR builds and fork runs cannot assume the CI role.

**In a production project** you would typically:
- Use feature branches + PR review before merge to `main`.
- Have separate `staging` and `production` environments, each with their own IAM role and ECR lifecycle.
- Require status checks (tests, lint) to pass before a PR can merge.

### No test job

The project's only tests are Cypress end-to-end tests that hit `http://localhost:3000` and require a fully running frontend + backend + MongoDB stack. Running that in GitHub Actions would mean spinning up a service container cluster, seeding data, and managing port mapping — significant overhead for a demo project that already validates correctness via Docker Compose locally.

The backend's `package.json` explicitly has no test runner (`"test": "echo 'Error: no test specified' && exit 1"`).

**In a production project** you would add:
- Unit tests + integration tests runnable without a live DB (mocked).
- Cypress in CI using `docker-compose` inside the runner, or a service like Cypress Cloud.
- Lint steps (`eslint`, `prettier --check`).

### Local Terraform state

State is stored in `infra/terraform/ci/terraform.tfstate` locally. This is fine for a single developer.

**In a production project** you would use a remote backend:
- **S3 + DynamoDB** for locking: enables multiple engineers to run Terraform safely.
- State encryption via S3 SSE.
- Separate state files per environment (`dev`, `staging`, `prod`).

### OIDC instead of access keys

No AWS access keys are stored in GitHub Secrets. GitHub exchanges a short-lived OIDC token for temporary STS credentials at runtime. The token is scoped to this exact repo + branch combination.

### Image tagging: `latest` + commit SHA

Both tags are pushed simultaneously:
- **`latest`**: easy to pull "the most recent" image during initial k8s deployment.
- **`<sha>`**: immutable, enables rollbacks and audit — you can pin a k8s deployment to the exact commit that was built.

### ECR lifecycle policy

Each repository retains the last **10 images**, older ones are expired automatically. Prevents unbounded storage growth. Adjust `ecr_image_retention_count` in `terraform.tfvars` if needed.

---

## Directory Layout

```
infra/
└── terraform/
    └── ci/               ← only CI resources here
        ├── main.tf       ← ECR, OIDC provider, IAM role + policy
        ├── variables.tf
        ├── outputs.tf    ← prints role_arn after apply
        └── terraform.tfvars

.github/
└── workflows/
    └── ci.yml            ← the pipeline
```

Future Terraform modules (networking, k8s cluster, etc.) will live as siblings of `ci/` under `infra/terraform/`.

---

## Setup Steps

### 1. Apply Terraform

```bash
cd infra/terraform/ci
terraform init
terraform plan   # review what will be created
terraform apply
```

After apply, note the printed `role_arn` output.

### 2. Add GitHub Secret

In your repository: **Settings → Secrets and variables → Actions → New repository secret**

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | *(value from terraform output)* |

### 3. Push to main

The workflow triggers automatically. Monitor progress in **Actions** tab.

---

## Resources Created

| Resource | Name/ID |
|---|---|
| ECR repo | `mern-project-frontend` |
| ECR repo | `mern-project-backend` |
| IAM OIDC provider | `token.actions.githubusercontent.com` |
| IAM role | `baykarcase-github-ci` |
| IAM inline policy | `ecr-push` (scoped to the two repos above) |
