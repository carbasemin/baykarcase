variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-1"
}

variable "github_repo" {
  description = "GitHub repo in 'owner/name' format that is allowed to assume the CI role"
  type        = string
  default     = "emincarbas/baykarcase"
}

variable "ecr_image_retention_count" {
  description = "Number of images to retain per ECR repository (older images are expired)"
  type        = number
  default     = 10
}

variable "common_tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "baykarcase"
    ManagedBy   = "terraform"
    Environment = "ci"
  }
}
