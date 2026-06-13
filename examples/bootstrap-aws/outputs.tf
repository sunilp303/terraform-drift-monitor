output "role_arn" {
  description = "Set this as the DRIFT_DETECTOR_ROLE_ARN secret in the caller repo."
  value       = aws_iam_role.drift_detector.arn
}

output "audit_bucket" {
  description = "Set this as the AUDIT_S3_BUCKET secret in the caller repo."
  value       = aws_s3_bucket.audit.bucket
}
