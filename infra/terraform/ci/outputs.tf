output "role_arn" {
  description = "ARN of the IAM role to add as AWS_ROLE_ARN in GitHub Actions secrets"
  value       = aws_iam_role.github_ci.arn
}

output "ecr_frontend_url" {
  description = "ECR repository URL for the MERN frontend image"
  value       = aws_ecr_repository.mern_frontend.repository_url
}

output "ecr_backend_url" {
  description = "ECR repository URL for the MERN backend image"
  value       = aws_ecr_repository.mern_backend.repository_url
}
