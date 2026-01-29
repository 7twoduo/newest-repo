#####################################################################################################################
#                                           LAB 2: CloudFront CDN with Origin Cloaking
#####################################################################################################################

#                                           Variables for CloudFront
variable "app_subdomain" {
  description = "Subdomain for the app (e.g., 'app' for app.domain.com)"
  type        = string
  default     = "app"
}

#                                           CloudFront ACM Certificate (must be in us-east-1)
# Note: CloudFront requires certificates in us-east-1 (provider alias defined in 1a.tf)

resource "aws_acm_certificate" "cloudfront_cert" {
  count    = var.enable_cloudfront ? 1 : 0
  provider = aws.us_east_1

  domain_name               = var.root_domain_name
  subject_alternative_names = ["*.${var.root_domain_name}"]
  validation_method         = "DNS"

  tags = {
    Name = "${var.Environment}-cloudfront-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cloudfront_cert_validation" {
  for_each = var.enable_cloudfront ? {
    for dvo in aws_acm_certificate.cloudfront_cert[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id = aws_route53_zone.primary.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront_cert_validation" {
  count    = var.enable_cloudfront ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront_cert[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cloudfront_cert_validation : r.fqdn]
}

#####################################################################################################################
#                                           Origin Cloaking - Secret Header
#####################################################################################################################

# Secret header value for origin cloaking - CloudFront sends this, ALB validates it
resource "random_password" "origin_header_secret" {
  count   = var.enable_cloudfront ? 1 : 0
  length  = 32
  special = false
}

#####################################################################################################################
#                                           Origin Cloaking - Security Group Rules
#####################################################################################################################

# CloudFront origin-facing prefix list for restricting ALB access
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  count = var.enable_cloudfront ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

# Allow only CloudFront IPs to reach ALB on port 443
resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront_443" {
  count             = var.enable_cloudfront ? 1 : 0
  security_group_id = aws_security_group.EC2_SG.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id

  description = "Allow HTTPS from CloudFront only"
}

#####################################################################################################################
#                                           Origin Cloaking - ALB Listener Rules
#####################################################################################################################

# Forward requests with valid secret header
resource "aws_lb_listener_rule" "require_origin_header" {
  count        = var.enable_cloudfront ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hidden_target_group.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_header_secret[0].result]
    }
  }
}

# Block all requests without the secret header (lower priority = evaluated last)
resource "aws_lb_listener_rule" "block_direct_access" {
  count        = var.enable_cloudfront ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden - Direct access not allowed"
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

#####################################################################################################################
#                                           CloudFront Cache Policies
#####################################################################################################################

# Aggressive caching for static content
resource "aws_cloudfront_cache_policy" "static_cache" {
  count   = var.enable_cloudfront ? 1 : 0
  name    = "${var.Environment}-cache-static"
  comment = "Aggressive caching for static assets"

  default_ttl = 86400    # 1 day
  max_ttl     = 31536000 # 1 year
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

# No caching for API endpoints (safe default)
resource "aws_cloudfront_cache_policy" "api_no_cache" {
  count   = var.enable_cloudfront ? 1 : 0
  name    = "${var.Environment}-cache-api-disabled"
  comment = "Disable caching for API endpoints"

  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "all"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Authorization", "Host"]
      }
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

#####################################################################################################################
#                                           CloudFront Origin Request Policies
#####################################################################################################################

# Forward necessary values for API calls
resource "aws_cloudfront_origin_request_policy" "api_origin" {
  count   = var.enable_cloudfront ? 1 : 0
  name    = "${var.Environment}-orp-api"
  comment = "Forward necessary values for API calls"

  cookies_config {
    cookie_behavior = "all"
  }
  query_strings_config {
    query_string_behavior = "all"
  }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Authorization", "Content-Type", "Origin", "Host", "Accept"]
    }
  }
}

# Minimal forwarding for static assets
resource "aws_cloudfront_origin_request_policy" "static_origin" {
  count   = var.enable_cloudfront ? 1 : 0
  name    = "${var.Environment}-orp-static"
  comment = "Minimal forwarding for static assets"

  cookies_config {
    cookie_behavior = "none"
  }
  query_strings_config {
    query_string_behavior = "none"
  }
  headers_config {
    header_behavior = "none"
  }
}

#####################################################################################################################
#                                           CloudFront Response Headers Policy
#####################################################################################################################

resource "aws_cloudfront_response_headers_policy" "static_headers" {
  count   = var.enable_cloudfront ? 1 : 0
  name    = "${var.Environment}-rsp-static"
  comment = "Add Cache-Control for static content"

  custom_headers_config {
    items {
      header   = "Cache-Control"
      override = true
      value    = "public, max-age=86400, immutable"
    }
  }
}

#####################################################################################################################
#                                           CloudFront WAF (CLOUDFRONT scope)
#####################################################################################################################

resource "aws_wafv2_web_acl" "cloudfront_waf" {
  count    = var.enable_cloudfront ? 1 : 0
  provider = aws.us_east_1

  name  = "${var.Environment}-cloudfront-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.Environment}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.Environment}-cf-waf-common"
      sampled_requests_enabled   = true
    }
  }

  tags = {
    Name = "${var.Environment}-cloudfront-waf"
  }
}

#####################################################################################################################
#                                           CloudFront Distribution
#####################################################################################################################

resource "aws_cloudfront_distribution" "main" {
  count = var.enable_cloudfront ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.Environment}-cloudfront-distribution"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # Use only North America and Europe

  # ALB Origin with secret header for origin cloaking
  origin {
    origin_id   = "${var.Environment}-alb-origin"
    domain_name = aws_lb.hidden_alb.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Secret header for origin verification
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_header_secret[0].result
    }
  }

  # Default behavior (API/dynamic content - no caching)
  default_cache_behavior {
    target_origin_id       = "${var.Environment}-alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = aws_cloudfront_cache_policy.api_no_cache[0].id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api_origin[0].id

    compress = true
  }

  # Static content behavior (aggressive caching)
  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "${var.Environment}-alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id            = aws_cloudfront_cache_policy.static_cache[0].id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.static_origin[0].id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.static_headers[0].id

    compress = true
  }

  # Attach CloudFront WAF
  web_acl_id = aws_wafv2_web_acl.cloudfront_waf[0].arn

  # Domain aliases
  aliases = [
    var.root_domain_name,
    "www.${var.root_domain_name}",
    "${var.app_subdomain}.${var.root_domain_name}"
  ]

  # SSL Certificate (must be in us-east-1)
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cloudfront_cert[0].arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "${var.Environment}-cloudfront"
  }

  depends_on = [aws_acm_certificate_validation.cloudfront_cert_validation]
}

#####################################################################################################################
#                                           Route53 Records - Point to CloudFront
#####################################################################################################################

# Apex domain points to CloudFront (when enabled)
resource "aws_route53_record" "apex_to_cloudfront" {
  count   = var.enable_cloudfront ? 1 : 0
  zone_id = aws_route53_zone.primary.zone_id
  name    = var.root_domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# www subdomain points to CloudFront (when enabled)
resource "aws_route53_record" "www_to_cloudfront" {
  count   = var.enable_cloudfront ? 1 : 0
  zone_id = aws_route53_zone.primary.zone_id
  name    = "www.${var.root_domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# App subdomain points to CloudFront
resource "aws_route53_record" "app_to_cloudfront" {
  count   = var.enable_cloudfront ? 1 : 0
  zone_id = aws_route53_zone.primary.zone_id
  name    = "${var.app_subdomain}.${var.root_domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

#####################################################################################################################
#                                           Outputs
#####################################################################################################################

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.main[0].id : null
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.main[0].domain_name : null
}
