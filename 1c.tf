#s3 Bucket
resource "aws_s3_bucket" "spire" {
  bucket = "aws-alb-logs-${data.aws_region.current.region}-${local.Environment}-${data.aws_caller_identity.current.account_id}"
  region = data.aws_region.current.region

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}

#                            ELITE TIP: USE AWS POLICY GENERATOR SAVES SUFFERING
#S3 Bucket to store ALB logs
resource "aws_s3_bucket_policy" "lb_bucket_policy" {
  bucket = aws_s3_bucket.spire.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Deny insecure transport (TLS-only)
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          "arn:aws:s3:::${aws_s3_bucket.spire.id}",
          "arn:aws:s3:::${aws_s3_bucket.spire.id}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      # REQUIRED: ALB access logs - uses regional ELB service account
      {
        Sid    = "AllowELBLogDelivery"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.main.arn
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${aws_s3_bucket.spire.id}/${var.alb_access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      # ALB access logs via service principal (recommended for newer regions)
      {
        Sid    = "AllowELBPutObject"
        Effect = "Allow"
        Principal = {
          Service = "elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${aws_s3_bucket.spire.id}/${var.alb_access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      }
    ]
  })
}
# Use if terraform doesn't return an identifier
# import {
#   to = aws_lb.hidden_alb
#   id = "arn"
# }

resource "aws_lb" "hidden_alb" {
  name               = "LoadExternal"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.EC2_SG.id]

  subnets = [
    aws_subnet.Star_Public_AZ1.id,
    aws_subnet.Star_Public_AZ2.id,
  ]
  # access_logs {
  #   bucket  = var.s3_bucket
  #   prefix  = var.alb_access_logs_prefix
  #   enabled = true
  # }
  tags = {
    Name = "App1LoadBalancer"
  }
}

#                                      DOMAIN NAME : ROUTE 53
#############################################################################################
#Target Group for Load Balancer
resource "aws_lb_target_group" "hidden_target_group" {
  name     = "hidden-target-group"
  port     = 80 # You forgot the Port here
  protocol = "HTTP"
  vpc_id   = local.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
    matcher             = "200-399"
  }

  tags = {
    Name = "Target Group for hidden target_group"
  }
}
#                                   Listeners for TARGET GROUP
import {
  to = aws_route53domains_registered_domain.unshieldedhollow
  id = "unshieldedhollow.click" # Your domain here
}


resource "aws_route53_zone" "primary" {
  name = var.root_domain_name
}
resource "aws_route53domains_registered_domain" "unshieldedhollow" {
  domain_name = var.root_domain_name

  name_server {
    name = aws_route53_zone.primary.name_servers[0]
  }
  name_server {
    name = aws_route53_zone.primary.name_servers[1]
  }
  name_server {
    name = aws_route53_zone.primary.name_servers[2]
  }
  name_server {
    name = aws_route53_zone.primary.name_servers[3]
  }
}
#              Use this or the other one above, this one below is better since its compact
#              the other one above is more descriptive
/*
resource "aws_route53domains_registered_domain" "wisdomseekers" {
  domain_name = var.root_domain_name

  dynamic "name_server" {
    for_each = aws_route53_zone.primary.name_servers
    content {
      name = name_server.value
    }
  }
}
*/
resource "aws_acm_certificate" "hidden_target_group2" {
  domain_name       = var.root_domain_name
  validation_method = "DNS"

  tags = {
    Name = "hidden target_group certificate"
  }
}
resource "aws_route53_record" "cert_validation" {
  for_each = (
    var.certificate_validation_method == "DNS" &&
    length(aws_acm_certificate.hidden_target_group2.domain_validation_options) > 0
    ) ? {
    for dvo in aws_acm_certificate.hidden_target_group2.domain_validation_options :
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
}
# Explanation: DNS now points to ALB
resource "aws_route53_record" "hidden_apex_to_alb" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = var.root_domain_name
  type    = "A"

  alias {
    name                   = aws_lb.hidden_alb.dns_name
    zone_id                = aws_lb.hidden_alb.zone_id
    evaluate_target_health = true
  }
}

# Explanation: www.unshieldedshadow.com also points to ALB — same doorway, different sign.
resource "aws_route53_record" "hidden_www_to_alb" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "www"
  type    = "A"

  alias {
    name                   = aws_lb.hidden_alb.dns_name
    zone_id                = aws_lb.hidden_alb.zone_id
    evaluate_target_health = true
  }
}


resource "aws_acm_certificate_validation" "star_cert_validation1" {
  count                   = var.certificate_validation_method == "DNS" ? 1 : 0
  certificate_arn         = aws_acm_certificate.hidden_target_group2.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.hidden_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.hidden_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.hidden_target_group2.arn



  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hidden_target_group.arn
  }
  depends_on = [aws_acm_certificate_validation.star_cert_validation1]
}

resource "aws_autoscaling_attachment" "load_asg" {
  autoscaling_group_name = aws_autoscaling_group.bar.id
  lb_target_group_arn    = aws_lb_target_group.hidden_target_group.arn
}

#                                 WAF : Web Application Firewall
resource "aws_wafv2_web_acl" "alb_waf" {
  name        = "alb_waf_defender"
  description = "This is to protect my application load balancer through WAF"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.Environment}-waf01"
    sampled_requests_enabled   = true
  }

  # Explanation: AWS managed rules are like hiring Rebel commandos — they’ve seen every trick.
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
      metric_name                = "${local.Environment}-waf-common"
      sampled_requests_enabled   = true
    }
  }

  tags = {
    Name = "${local.Environment}-waf01"
  }
}

resource "aws_wafv2_web_acl_association" "chewbacca_waf_assoc01" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_lb.hidden_alb.arn
  web_acl_arn  = aws_wafv2_web_acl.alb_waf.arn
}

############################################
# CloudWatch Alarm: ALB 5xx -> SNS
############################################
resource "aws_cloudwatch_metric_alarm" "chewbacca_alb_5xx_alarm01" {
  alarm_name          = "${local.Environment}-alb-5xx-alarm01"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alb_5xx_evaluation_periods
  threshold           = var.alb_5xx_threshold
  period              = var.alb_5xx_period_seconds
  statistic           = "Sum"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_ELB_5XX_Count"

  dimensions = {
    LoadBalancer = aws_lb.hidden_alb.arn_suffix
  }

  alarm_actions = [aws_sns_topic.health_check_topic.arn]

  tags = {
    Name = "${local.Environment}-alb-5xx-alarm01"
  }
}

############################################
# CloudWatch Dashboard (Skeleton)
############################################

# Explanation: Dashboards are your cockpit HUD — Chewbacca wants dials, not vibes.
resource "aws_cloudwatch_dashboard" "chewbacca_dashboard01" {
  dashboard_name = "${local.Environment}-dashboard01"

  # TODO: students can expand widgets; this is a minimal workable skeleton
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.hidden_alb.arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", ".", aws_lb.hidden_alb.arn_suffix]
          ]
          period = 300
          stat   = "Sum"
          region = data.aws_region.current.region
          title  = "Chewbacca ALB: Requests + 5XX"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.hidden_alb.arn_suffix]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.region
          title  = "Chewbacca ALB: Target Response Time"
        }
      }
    ]
  })
}
##############################################################################################################################################################################################################
# Explanation: The zone apex is the throne room—chewbacca-growl.com itself should lead to the ALB.


############################################
# S3 bucket for ALB access logs
############################################

# Explanation: Block public access—Chewbacca does not publish the ship’s black box to the galaxy.
resource "aws_s3_bucket_public_access_block" "chewbacca_alb_logs_pab01" {
  count = var.s3_bucket_no_access ? 1 : 0

  bucket                  = aws_s3_bucket.spire.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Explanation: Bucket ownership controls prevent log delivery chaos—Chewbacca likes clean chain-of-custody.
resource "aws_s3_bucket_ownership_controls" "alb_logs_owner01" {
  count = var.s3_bucket_no_access ? 1 : 0

  bucket = aws_s3_bucket.spire.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Explanation: TLS-only—Chewbacca growls at plaintext and throws it out an airlock.
resource "aws_s3_bucket_policy" "alb_logs_policy01" {
  count = var.s3_bucket_no_access ? 1 : 0

  bucket = aws_s3_bucket.spire.id

  # NOTE: This is a skeleton. Students may need to adjust for region/account specifics.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.spire.arn,
          "${aws_s3_bucket.spire.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid    = "AllowELBPutObject"
        Effect = "Allow"
        Principal = {
          Service = "elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.spire.arn}/${var.alb_access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      }
    ]
  })
}


#####################################################################################################################
#                                           WAF Log Group
#####################################################################################################################

resource "aws_cloudwatch_log_group" "star-alb-log1" {
  count = var.waf_log_destination == "cloudwatch" ? 1 : 0

  # NOTE: AWS requires WAF log destination names start with aws-waf-logs- (students must not rename this).
  name              = "aws-waf-logs-${local.Environment}-webacl01"
  retention_in_days = var.waf_log_retention_days

  tags = {
    Name = "${local.Environment}-waf-log-group01"
  }
}

# Explanation: This wire connects the shield generator to the black box—WAF -> CloudWatch Logs.
resource "aws_wafv2_web_acl_logging_configuration" "chewbacca_waf_logging01" {
  count = var.enable_waf && var.waf_log_destination == "cloudwatch" ? 1 : 0

  resource_arn = aws_wafv2_web_acl.alb_waf.arn
  log_destination_configs = [
    aws_cloudwatch_log_group.star-alb-log1[0].arn
  ]

  # TODO: Students can add redacted_fields (authorization headers, cookies, etc.) as a stretch goal.
  # redacted_fields { ... }

  depends_on = [aws_wafv2_web_acl.alb_waf]
}

############################################
# Option 2: S3 destination (direct)
############################################

# Explanation: S3 WAF logs are the long-term archive—Chewbacca likes receipts that survive dashboards.
resource "aws_s3_bucket" "star_waf_bucket_uno" {
  count = var.waf_log_dest == "s3" ? 1 : 0

  bucket = "aws-waf-logs-${data.aws_region.current.region}-${local.Environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${local.Environment}-waf-logs-bucket01"
  }
}

# Explanation: Public access blocked—WAF logs are not a bedtime story for the entire internet.
resource "aws_s3_bucket_public_access_block" "chewbacca_waf_logs_pab01" {
  count = var.waf_log_dest == "s3" ? 1 : 0

  bucket                  = aws_s3_bucket.star_waf_bucket_uno[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

}

# Explanation: Connect shield generator to archive vault—WAF -> S3.
resource "aws_wafv2_web_acl_logging_configuration" "chewbacca_waf_logging_s3_01" {
  count = var.enable_waf && var.waf_log_dest == "s3" ? 1 : 0

  resource_arn = aws_wafv2_web_acl.alb_waf.arn
  log_destination_configs = [
    aws_s3_bucket.star_waf_bucket_uno[0].arn
  ]

  depends_on = [aws_wafv2_web_acl.alb_waf, aws_wafv2_web_acl_logging_configuration.chewbacca_waf_logging_s3_01]
}

############################################
# Option 3: Firehose destination (classic “stream then store”)
############################################

# Explanation: Firehose is the conveyor belt—WAF logs ride it to storage (and can fork to SIEM later).
resource "aws_s3_bucket" "star_firehouse_waf_log" {
  count = var.firehose_log == "firehose" ? 1 : 0

  bucket = "${data.aws_region.current.region}-${local.Environment}-waf-firehose-dest-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${local.Environment}-waf-firehose-dest-bucket01"
  }
}

# Explanation: Firehose needs a role—Chewbacca doesn’t let random droids write into storage.
resource "aws_iam_role" "star_fire_hose1" {
  count = var.firehose_log == "firehose" ? 1 : 0
  name  = "${local.Environment}-firehose-role01"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Explanation: Minimal permissions—allow Firehose to put objects into the destination bucket.
resource "aws_iam_role_policy" "chewbacca_firehose_policy01" {
  count = var.firehose_log == "firehose" ? 1 : 0
  name  = "${local.Environment}-firehose-policy01"
  role  = aws_iam_role.star_fire_hose1[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.star_firehouse_waf_log[0].arn,
          "${aws_s3_bucket.star_firehouse_waf_log[0].arn}/*"
        ]
      }
    ]
  })
}

# Explanation: The delivery stream is the belt itself—logs move from WAF -> Firehose -> S3.
resource "aws_kinesis_firehose_delivery_stream" "Star_Firehose_delivery1" {
  count       = var.firehose_log == "firehose" ? 1 : 0
  name        = "aws-waf-logs-${local.Environment}-firehose01"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.star_fire_hose1[0].arn
    bucket_arn = aws_s3_bucket.star_firehouse_waf_log[0].arn
    prefix     = "waf-logs/"
  }
}

# Explanation: Connect shield generator to conveyor belt—WAF -> Firehose stream.
resource "aws_wafv2_web_acl_logging_configuration" "chewbacca_waf_logging_firehose01" {
  count = var.enable_waf && var.firehose_log == "firehose" ? 1 : 0

  resource_arn = aws_wafv2_web_acl.alb_waf.arn
  log_destination_configs = [
    aws_kinesis_firehose_delivery_stream.Star_Firehose_delivery1[0].arn
  ]

  depends_on = [aws_wafv2_web_acl.alb_waf, aws_wafv2_web_acl_logging_configuration.chewbacca_waf_logging_s3_01]
}



#                                 CDN : Content Delivery Network

