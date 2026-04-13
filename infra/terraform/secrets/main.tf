terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_secretsmanager_secret" "atlas_uri" {
  name        = "baykarcase/atlas-uri"
  description = "MongoDB Atlas connection string for MERN project"
  tags        = var.common_tags
}

resource "aws_secretsmanager_secret_version" "atlas_uri" {
  secret_id     = aws_secretsmanager_secret.atlas_uri.id
  secret_string = var.atlas_uri
}
