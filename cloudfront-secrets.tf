resource "random_password" "origin_secret" {
  length  = 32
  special = false
}

# Store the secret in Secrets Manager
resource "aws_secretsmanager_secret" "origin_verify" {
  name                    = "cloudfront/origin-verify-header"
  description             = "Secret header for CloudFront origin verification"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "origin_verify" {
  secret_id     = aws_secretsmanager_secret.origin_verify.id
  secret_string = random_password.origin_secret.result
}

# Secret header value (store in Secrets Manager or SSM in production)
variable "origin_secret" {
  default   = "my-secret-header-value-12345"
  sensitive = true
}
