# Baykar Case Study: MERN & CI/CD Deployment

This repository encapsulates the full deployment lifecycle for a supplied MERN stack application onto an enterprise-grade AWS Kubernetes architecture.

## Architecture Overview

The infrastructure was built with modularity and security in mind, leveraging modern cloud-native practices:
- **Cloud Provider:** AWS
- **Orchestration:** Amazon Elastic Kubernetes Service (EKS) `v1.35`
- **Network / Gateway:** AWS Application Load Balancer (ALB)
- **Container Registry:** Amazon Elastic Container Registry (ECR)
- **Database:** MongoDB Atlas (M0 Free Tier)
- **Traffic Routing / DNS:** Cloudflare (Flexible SSL proxy)
- **Infrastructure as Code:** Terraform
- **Kubernetes Packaging:** Helm

## CI Pipeline (GitHub Actions)

A streamlined GitHub Actions workflow was created in `.github/workflows/ci.yml`.
- **Keyless Authentication:** We use AWS OIDC (OpenID Connect) to authenticate the pipeline, completely avoiding hardcoded AWS Secret Keys.
- **Image Building:** It builds separate images for the MERN Backend and Frontend.
- **Layer Caching:** Incorporates Docker Buildx GitHub cache to cut down build times.
- **Testing Caveat:** The provided application only shipped with Cypress End-to-End tests which require a live environment stack. Thus, standard CI tests were bypassed in favor of a pure build/lint/push pipeline.

## Deployment (CD & Kubernetes)

### 1. Infrastructure Provisioning
Deployment infrastructure is segmented into decoupled Terraform modules:
- `infra/terraform/ci/`: Provisions ECR repositories and the GitHub OIDC provider.
- `infra/terraform/secrets/`: Provisions AWS Secrets Manager stores parameters safely.
- `infra/terraform/eks/`: Provisions a VPC with NAT Gateways, the EKS cluster utilizing Spot instances (for cost savings), and IAM Roles for Service Accounts (IRSA).

### 2. Cluster Add-ons (Helm)
Before deploying the application, the cluster requires core controller add-ons:
```bash
# Add Required Helm Repositories
helm repo add eks https://aws.github.io/eks-charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install AWS Load Balancer Controller
# Requires ServiceAccount explicit creation & IRSA mapping
ALB_ROLE_ARN=$(terraform -chdir=infra/terraform/eks output -raw aws_load_balancer_controller_role_arn)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=baykarcase \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE_ARN

# Install External Secrets Operator (ESO)
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set installCRDs=true
```

### 3. Application Deployment
- `helm/mern-project/`: A custom Helm chart that deploys the application with precise resource limits, ClusterIP networking, ESO configurations, and evaluating an ALB Ingress Controller spec.

```bash
cd helm/mern-project/
helm upgrade --install mern-project . --namespace mern-project --create-namespace
```

### 4. Monitoring Stack
The monitoring namespace (`monitoring`) contains the observability stack:

**Components:**
| Component | Description |
|-----------|-------------|
| Prometheus | Metrics collection (kube-prometheus-stack) |
| Grafana | Dashboards & visualization |
| Loki | Log aggregation |
| Fluentd | Log collection (DaemonSet) |

Access is via port-forwarding.

**Alerts configured:**
| Alert | Severity | Description |
|-------|---------|-------------|
| PodCrashLooping | critical | Pod restarting frequently |
| NoBackendPods | critical | No backend replicas available |
| HTTPErrorsHigh | warning | HTTP 5xx errors > 5% |
| MongoDBConnectionError | critical | Connection errors in logs (Loki) |
| MongoDBServerSelectionError | critical | Server selection failures (Loki) |
| MongoDBAuthenticationError | critical | Auth failures in logs (Loki) |
| MongoDBTLSErrors | critical | TLS/SSL errors (Loki) |

**Note:** MongoDB Atlas has its own built-in alerting for database-level metrics (disk usage, CPU, memory), configured from UI.
---

## Problems Encountered & Solved

Throughout the deployment phase, several realistic cloud-engineering constraints became apparent and were resolved:

### 1. Ingress Rewriting vs. ALB Controller
**Problem:** Typical Nginx Ingress controllers support `rewrite-target` annotations, allowing a front-end to hit `/api/record` and seamlessly routing to `/record` on the backend code. AWS Application Load Balancer does *not* support path rewriting.
**Solution:** We modified the Express backend's router configuration in `server.mjs` to genuinely listen on the `/api` route prefix. 

### 2. External Secrets API Deprecation & Wildcards
**Problem 1:** Helm blocked the installation of the ExternalSecret object stating `no matches for kind "ExternalSecret" in version "external-secrets.io/v1beta1"`.
**Solution 1:** Newer versions of the `external-secrets` chart removed the deprecated `v1beta1` schema. We updated the Helm templates to use `external-secrets.io/v1`.
**Problem 2:** The External Secrets operator received an IAM `AccessDenied` error.
**Solution 2:** AWS Secrets Manager injects a random 6-character suffix into ARNs (e.g., `baykarcase/atlas-uri-zDW7qB`). Our Terraform policy originally used a `baykarcase-*` wildcard, which fails to match directories. We corrected this to `baykarcase/*` allowing ESO to authenticate.

### 3. Cascading Failure: ALB Webhook & Service Account Mismatch
**Problem:** After provisioning the EKS cluster, the initial `aws-load-balancer-controller` Helm installation failed silently. The v5+ Terraform `iam-role-for-service-accounts-eks` module provisions the AWS IAM Role but no longer automatically creates the Kubernetes `ServiceAccount`. As a result:
1. The ALB Deployment created a ReplicaSet which continuously failed to schedule pods because the `aws-load-balancer-controller` ServiceAccount did not exist.
2. Even without pods running, the ALB chart successfully registered its `MutatingWebhookConfiguration` with the Kubernetes API.
3. When we immediately tried to install the `external-secrets` operator, Helm timed out (`failed calling webhook... no endpoints available`) because the API Server was trying to route the installation request through the non-existent ALB pods!

**Solution:** We had to manually break the jam and redeploy:
1. Ran `helm upgrade` on the ALB controller, explicitly forcing it to create the ServiceAccount (`--set serviceAccount.create=true`) and mapping the Terraform IAM Role ARN to it via annotations.
2. Ran `kubectl delete rs` on the stuck ALB ReplicaSets to force the deployment to immediately spawn new pods mapped to the correct ServiceAccount.
3. Waited for the ALB webhooks to come online and turn `Ready`.
4. Re-ran the `helm upgrade --install external-secrets` command which then seamlessly completed.

### 4. Cloudflare Proxy HTTPS Timeouts
**Problem:** Launching the app returned "Connection Timed Out" (Error 522) when loading `https://`.
**Solution:** Cloudflare's SSL mode was set to "Full/Strict", forcing Cloudflare to talk to generating ALB via `HTTPS (Port 443)`. Because the ALB was designed as HTTP (Port 80) behind Cloudflare, the packets were dropped. Flipping Cloudflare to "Flexible" resolved the timeout instantly. In the source code, `REACT_APP_API_URL` was then successfully updated to `https://` to avoid browser Mixed Content errors.

### 5. MongoDB Network Access `tlsv1 alert 80`
**Problem:** The backend threw a generic OpenSSL error: `MongoServerSelectionError: tlsv1 alert internal error (alert number 80)`.
**Solution:** This cryptic driver error occurs when MongoDB Atlas terminates the handshake because the client IP is not registered on the Atlas Network Access List. Whitelisting the connection (`0.0.0.0/0`) within the Atlas UI fixed it perfectly.
