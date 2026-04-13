variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "atlas_uri" {
  description = "The MongoDB connection string (e.g. mongodb+srv://...)"
  type        = string
  sensitive   = true
}

variable "common_tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "baykarcase"
    ManagedBy   = "terraform"
    Environment = "production"
  }
}
