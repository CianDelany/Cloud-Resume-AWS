output "website_url" {
  description = "The public URL of your CloudFront resume"
  value       = "https://${aws_cloudfront_distribution.cv_distribution.domain_name}"
}

output "s3_bucket_name" {
  description = "The name of your S3 bucket"
  value       = aws_s3_bucket.cv_bucket.id
}