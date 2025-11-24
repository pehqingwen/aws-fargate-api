data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

resource "aws_security_group" "alb" {
  name        = "fargate-api-alb-sg"
  description = "ALB ingress" # IMPORTANT: match the existing description
  vpc_id      = data.aws_vpc.this.id

  # Ingress: existing HTTP + new HTTPS
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress: restricted to app port inside VPC
  egress {
    from_port   = 3000 # confirm this is your target port
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  tags = {
    Name    = "fargate-api-alb-sg"
    Env     = "dev"
    Project = "fargate-api"
  }
}


data "aws_iam_policy_document" "exec_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "exec_ecr" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

locals {
  api_container = {
    name  = "api"
    image = "${aws_ecr_repository.repo.repository_url}:latest"
    portMappings = [
      { containerPort = 3000, protocol = "tcp" }
    ]
    # 👇 limits
    memoryReservation = 512
    memory            = 1024
    environment = [
      { name = "PORT", value = "3000" },
      { name = "NODE_OPTIONS", value = "--max-old-space-size=256" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/fargate-api"
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
    # healthCheck = {
    #   command     = ["CMD-SHELL", "node -e \"require('http').get('http://localhost:3000/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\""]
    #   interval    = 30
    #   timeout     = 5
    #   retries     = 3
    #   startPeriod = 10
    # }
    essential = true
  }
}

# Execution role: used by the ECS agent to pull images & push logs
data "aws_iam_policy_document" "ecs_task_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution_role" {
  name               = "${var.project}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json
  tags               = { Project = var.project, Env = var.env }
}

resource "aws_iam_role_policy_attachment" "execution_role_managed" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Autoscaling: target 50% CPU
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 6
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu_scale" {
  name               = "${var.project}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = "ecs"

  target_tracking_scaling_policy_configuration {
    target_value = 50

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}


# Least-priv policy for the ECS task role to access the table
data "aws_iam_policy_document" "dynamo_access" {
  statement {
    sid = "DynamoCrud"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query"
    ]
    resources = [aws_dynamodb_table.items.arn]
  }
}

resource "aws_iam_policy" "dynamo_access" {
  name   = "${var.project}-dynamo-access"
  policy = data.aws_iam_policy_document.dynamo_access.json
}

resource "aws_iam_role_policy_attachment" "task_dynamo" {
  role       = aws_iam_role.task_role.name
  policy_arn = aws_iam_policy.dynamo_access.arn
}

# --- WAFv2 Web ACL (REGIONAL) ---
resource "aws_wafv2_web_acl" "alb_waf" {
  name        = "${var.project}-waf"
  description = "Basic managed protections"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-waf"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    override_action {
      none {}
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common"
      sampled_requests_enabled   = true
    }
  }
}

# was: resource_arn = aws_lb.this.arn
resource "aws_wafv2_web_acl_association" "alb_assoc" {
  resource_arn = data.aws_lb.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.alb_waf.arn
}


# ALB 5xx rate alarm
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = data.aws_lb.alb.arn_suffix }
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
}

# ECS CPU > 80% alarm
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.project}-ecs-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name, ServiceName = aws_ecs_service.api.name }
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 2
  period              = 60
  statistic           = "Average"
}

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket        = "${var.project}-cloudtrail-${data.aws_region.current.name}"
  force_destroy = true

  tags = {
    Name = "${var.project}-cloudtrail-logs"
  }
}

# Minimal bucket policy so CloudTrail can write
data "aws_iam_policy_document" "cloudtrail_bucket_policy" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail_logs.arn]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions = [
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket_policy.json
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  is_organization_trail         = false # set true if using AWS Orgs + proper perms

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = {
    Name = "${var.project}-trail"
  }
}

resource "aws_guardduty_detector" "main" {
  enable = true

  # Optional: control finding publishing frequency
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_securityhub_account" "main" {
  # Optional:
  # auto_enable_controls = true  # automatically enable new controls when added
}
