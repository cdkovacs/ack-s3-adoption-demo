terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "test" {
  bucket = var.bucket_name

  tags = {
    Purpose   = "ack-adoption-demo"
    ManagedBy = "terraform-then-ack"
  }
}

# Non-default property: validation in phase 4 asserts this survives adoption.
resource "aws_s3_bucket_versioning" "test" {
  bucket = aws_s3_bucket.test.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "seed" {
  for_each = {
    "hello.txt" = "hello world from terraform\n"
    "data.json" = jsonencode({ created_by = "terraform", purpose = "ack-adoption-demo" })
    "notes.md"  = "# Test data\nSeeded by Terraform before ACK adoption.\n"
  }

  bucket  = aws_s3_bucket.test.id
  key     = each.key
  content = each.value
}
