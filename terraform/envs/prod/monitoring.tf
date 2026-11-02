resource "aws_sns_topic" "alarms" {
  tags              = { Name = "${local.name}-alarms", Component = "alerting", Tier = "platform" }
  name              = "${local.name}-alarms"
  kms_master_key_id = aws_kms_key.main.arn
}

resource "aws_sns_topic_policy" "alarms" {
  arn = aws_sns_topic.alarms.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alarms.arn
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alb_alarms = {
    alb-5xx = {
      metric = "HTTPCode_ELB_5XX_Count", stat = "Sum", threshold = 10, periods = 1, period = 300
      dims   = { LoadBalancer = aws_lb.this.arn_suffix }
    }
    target-5xx = {
      metric = "HTTPCode_Target_5XX_Count", stat = "Sum", threshold = 20, periods = 1, period = 300
      dims   = { LoadBalancer = aws_lb.this.arn_suffix }
    }
    unhealthy-frontend = {
      metric = "UnHealthyHostCount", stat = "Maximum", threshold = 1, periods = 2, period = 60
      dims   = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = aws_lb_target_group.frontend.arn_suffix }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb" {
  tags                = { Name = "${local.name}-${each.key}", Component = "alarm", Tier = "edge" }
  for_each            = local.alb_alarms
  alarm_name          = "${local.name}-${each.key}"
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value.metric
  statistic           = each.value.stat
  dimensions          = each.value.dims
  period              = each.value.period
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "data_host_status" {
  tags                = { Name = "${local.name}-data-host-status", Component = "alarm", Tier = "data" }
  alarm_name          = "${local.name}-data-host-status"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  dimensions          = { InstanceId = module.data_host.instance_id }
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# Containers that cannot reach MySQL/Redis/RabbitMQ show up here first
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  tags                = { Name = "${local.name}-${each.key}-cpu-high", Component = "alarm", Service = each.key, Tier = each.key == "frontend" ? "web" : "app" }
  for_each            = local.ecs_services
  alarm_name          = "${local.name}-${each.key}-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name, ServiceName = each.value.service_name }
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}
