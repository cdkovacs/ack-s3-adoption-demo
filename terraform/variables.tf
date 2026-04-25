variable "region" {
  type        = string
  description = "AWS region for the test bucket."
}

variable "bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name. The demo runner generates a fresh suffix per run."
}
