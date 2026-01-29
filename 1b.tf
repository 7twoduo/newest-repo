resource "aws_ssm_parameter" "port" {
  name        = "${var.parameter_location}port"
  description = "This is the RDS port"
  type        = "SecureString"
  value       = 3306
  tags = {
    environment = "production"
  }
}
resource "aws_ssm_parameter" "host" {
  name        = "${var.parameter_location}host"
  description = "This is the endpoint to the RDS instance"
  type        = "SecureString"
  value       = aws_db_instance.below_the_valley.address
  tags = {
    environment = "production"
  }
}
resource "aws_ssm_parameter" "db_name" {
  name        = "${var.parameter_location}db_name"
  description = "This is the name of the database within the RDS instance"
  type        = "SecureString"
  value       = aws_db_instance.below_the_valley.db_name
  tags = {
    environment = "production"
  }
}

#                                                                     Cloudwatch ALARM
#Cloudwatch Logs to watch database and EC2 for any failures and Alert me
resource "aws_sns_topic" "health_check_topic" {
  name = "ServiceHealthCheckTopic"
}
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.health_check_topic.arn
  protocol  = "email"
  # Replace with your email address
  endpoint = var.sns_email
  #Remember you have to confirm your subscription for this to work
}

#                                 Cloud Watch Alarms


# Cloudwatch Log Group
resource "aws_cloudwatch_log_group" "db_logs" {
  name              = "rds/${aws_db_instance.below_the_valley.id}/error"
  retention_in_days = var.cloudwatch_log_retention_days
}
resource "aws_cloudwatch_log_metric_filter" "connection_failure_filter" {
  name           = "DBConnectionFailureFilter"
  log_group_name = aws_cloudwatch_log_group.db_logs.name
  pattern        = "?ERROR ?FATAL ?CRITICAL ?Connection ?failed"
  # Adjust pattern based on exact error messages in your specific DB engine logs

  metric_transformation {
    name      = "DBConnectionFailureCount"
    namespace = "Custom/RDS"
    value     = "1"
  }
}
#     Cloudwatch log group for ec2
resource "aws_cloudwatch_log_group" "ec2_health" {
  name              = "/lab/${var.Environment}/ec2/health"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = {
    Name = "ec2-health-log-group"
  }
}

# EC2 Alarms
resource "aws_cloudwatch_metric_alarm" "asg_instance_unhealthy" {
  alarm_name          = "/lab/${local.Environment}/ec2/health"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = 1

  metric_name        = "StatusCheckFailed"
  namespace          = "AWS/EC2"
  period             = 60
  statistic          = "Maximum"
  treat_missing_data = "breaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.bar.name
  }

  alarm_description = "Triggers when an EC2 instance fails system or instance status checks"
  alarm_actions     = [aws_sns_topic.health_check_topic.arn]
}


#   RDS Alarms
resource "aws_cloudwatch_metric_alarm" "below_the_valley_db_alarm01" {
  alarm_name          = "${local.name_prefix}-db-connection-failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "DBConnectionErrors"
  namespace           = "Lab/RDSApp"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_actions       = [aws_sns_topic.health_check_topic.arn]
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.below_the_valley.identifier
  }
  tags = {
    Name = "${local.name_prefix}-alarm-db-fail"
  }

  depends_on = [aws_db_instance.below_the_valley]
}

#My Custom Metric for Cloudwatch Database logs
resource "aws_cloudwatch_metric_alarm" "connection_failure_alarm" {
  alarm_name          = "High-DB-Connection-Failure-Rate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 5
  metric_name         = aws_cloudwatch_log_metric_filter.connection_failure_filter.metric_transformation[0].name
  namespace           = "AWS/RDS"
  period              = 60 # Check every 60 seconds
  statistic           = "Average"
  threshold           = 1 # Trigger if 5 or more failures in the period
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.below_the_valley.identifier
  }
  alarm_description = "The following ${local.terradbname} RDS server is running into connection issues. Check to see what the problem is and if you cannont remedy it, replace it. Replace it in terraform by running -terraform apply -replace ${local.terradbname} (If you have access to the terraform this is the remedy) "
  alarm_actions     = [aws_sns_topic.health_check_topic.arn]

  depends_on = [aws_db_instance.below_the_valley]
}

#This tracks for when the CPU utilization is below 1 percent for more than 5 minutes which means the server is not running
resource "aws_cloudwatch_metric_alarm" "rds-CPUUtilization" {
  alarm_name          = "rds-CPUUtilization"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60 #Requirements is 5 minutes, so 300 seconds(50s X 2 periods = 100s x3 thresholds = 300s)
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.below_the_valley.identifier
  }
  alarm_description = "The following ${local.terradbname} RDS is not running because a running server CPU utilization  doesn't go lower than one. Check to see what the problem is and if you cannont remedy it, replace it. Replace it in terraform by running -terraform apply -replace ${local.terradbname} (If you have access to the terraform this is the remedy) "
  alarm_actions     = [aws_sns_topic.health_check_topic.arn]

  depends_on = [aws_db_instance.below_the_valley]
}

#Use RDS Snapshots to restore RDS in case of failure



#S3 Gateway VPC Endpoint for S3 access within the VPC
resource "aws_vpc_endpoint" "s3_gateway_endpoint" {
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.Private.id]

  tags = {
    Name = "S3-Gateway-Endpoint"
  }
}

# Cloudwatch Endpoint
resource "aws_vpc_endpoint" "logs" {
  vpc_id             = local.vpc_id
  service_name       = "com.amazonaws.${data.aws_region.current.region}.logs" # Use the specific service name for CloudWatch Logs
  vpc_endpoint_type  = "Interface"
  subnet_ids         = [aws_subnet.Star_Private_AZ1.id, aws_subnet.Star_Private_AZ2.id]
  security_group_ids = [aws_security_group.Endpoint_SG.id]

  # Enable private DNS names for the endpoint
  private_dns_enabled = true

  tags = {
    Name = "deathless-god-endpoint-cloudwatch-logs"
  }
}

#Secrets Manager VPC Endpoint
resource "aws_vpc_endpoint" "secrets_manager" {
  vpc_id              = local.vpc_id
  vpc_endpoint_type   = "Interface"
  service_name        = "com.amazonaws.${data.aws_region.current.region}.secretsmanager"
  subnet_ids          = [aws_subnet.Star_Private_AZ1.id, aws_subnet.Star_Private_AZ2.id]
  security_group_ids  = [aws_security_group.Endpoint_SG.id]
  private_dns_enabled = true

  tags = {
    Name = "SecretsManagerVPCEndpoint"
  }
}

#STS Endpoint, Theo doesn't mention it but this is necessary for EC2 to communicate with Secrets Manager
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = local.vpc_id
  vpc_endpoint_type   = "Interface"
  service_name        = "com.amazonaws.${data.aws_region.current.region}.sts"
  subnet_ids          = [aws_subnet.Star_Private_AZ1.id, aws_subnet.Star_Private_AZ2.id]
  security_group_ids  = [aws_security_group.Endpoint_SG.id]
  private_dns_enabled = true

  tags = {
    Name = "STSVPCEndpoint"
  }
}
# KMS Endpoint
resource "aws_vpc_endpoint" "kms" {
  vpc_id            = local.vpc_id
  vpc_endpoint_type = "Interface"
  service_name      = "com.amazonaws.${data.aws_region.current.region}.kms"
  subnet_ids = [
    aws_subnet.Star_Private_AZ1.id,
    aws_subnet.Star_Private_AZ2.id
  ]
  security_group_ids  = [aws_security_group.Endpoint_SG.id]
  private_dns_enabled = true

  tags = {
    Name = "KMS-VPCEndpoint"
  }
}

# EC2 Messages VPC Endpoint
resource "aws_vpc_endpoint" "ec2messages" {
  # The service name format is "com.amazonaws.<region>.ec2messages"
  service_name      = "com.amazonaws.${data.aws_region.current.region}.ec2messages"
  vpc_id            = local.vpc_id
  vpc_endpoint_type = "Interface"
  # Associate the endpoint with your private subnet IDs
  subnet_ids = [aws_subnet.Star_Private_AZ1.id, aws_subnet.Star_Private_AZ2.id]
  # Associate the dedicated security group
  security_group_ids = [aws_security_group.Endpoint_SG.id]
  # Enable private DNS names for seamless resolution within the VPC
  private_dns_enabled = true

  tags = {
    Name = "EC2Messages VPC Endpoint"
  }
}

# SSM VPC Endpoint
resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.Endpoint_SG.id]
  subnet_ids          = [aws_subnet.Star_Private_AZ1.id, aws_subnet.Star_Private_AZ2.id]
  private_dns_enabled = true

  tags = {
    Name = "ssmmessages-endpoint"
  }
}
resource "aws_vpc_endpoint" "ssm" {
  vpc_id             = local.vpc_id
  service_name       = "com.amazonaws.${data.aws_region.current.region}.ssm"
  vpc_endpoint_type  = "Interface"
  security_group_ids = [aws_security_group.Endpoint_SG.id]
  subnet_ids = [
    aws_subnet.Star_Private_AZ1.id,
    aws_subnet.Star_Private_AZ2.id
  ]
  private_dns_enabled = true

  tags = {
    Name = "ssm-endpoint"
  }
}
