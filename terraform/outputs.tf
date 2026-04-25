output "bucket_name" {
  value = aws_s3_bucket.test.id
}

# ETags become the integrity baseline for phase 40 (validate). Captured before phase 20
# (state rm) wipes Terraform's knowledge of these resources.
output "etags" {
  value = { for k, o in aws_s3_object.seed : k => o.etag }
}
