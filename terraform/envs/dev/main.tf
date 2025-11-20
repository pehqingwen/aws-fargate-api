// Terraform: dev environment (local state). Switch to S3 backend later as needed.
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# VPC (2-3 AZs) via community module
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "fargate-vpc"
  cidr = "10.10.0.0/16"

  azs             = var.azs
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Project = var.project
    Env     = var.env
  }
}


resource "aws_ecr_repository" "repo" {
  name                 = "fargate-api"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [image_tag_mutability, image_scanning_configuration, encryption_configuration]
  }

  tags = { Project = var.project, Env = var.env }
}



# Security Groups
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "ALB ingress"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project
    Env     = var.env
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_security_group" "ecs" {
  name        = "${var.project}-ecs-sg"
  description = "ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project
    Env     = var.env
  }

  lifecycle {
    prevent_destroy = true
  }
}

# === ALB (native resources instead of module) ===
resource "aws_lb" "this" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 60
  tags = {
    Project = var.project
    Env     = var.env
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_lb_target_group" "api" {
  name        = "${var.project}-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = {
    Project = var.project
    Env     = var.env
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Keep this HTTP listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ECS/ECR/Task
resource "aws_ecs_cluster" "this" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Project = var.project
    Env     = var.env
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

resource "aws_iam_role" "task_execution" {
  name               = "${var.project}-ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.exec_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_ecr" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task_role" {
  name               = "${var.project}-ecsTaskRole"
  assume_role_policy = data.aws_iam_policy_document.exec_assume.json
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project}"
  retention_in_days = 14
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

resource "aws_ecs_task_definition" "api" {
  family                   = var.project
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024" # task-level
  memory                   = "2048" # task-level
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([local.api_container])

  lifecycle {
    prevent_destroy = true
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


resource "aws_ecs_service" "api" {
  name            = "${var.project}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    # ⛔️ old (module) reference:
    # target_group_arn = module.alb.target_groups["api"].arn
    # ✅ new (native) reference:
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }

  lifecycle {
    ignore_changes  = [task_definition]
    prevent_destroy = true
  }

  # ⛔️ remove the old depends_on if it referenced the module:
  # depends_on = [module.alb]
  # ✅ optional: depend on the listener to ensure ordering:
  depends_on = [aws_lb_listener.http]
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

# DynamoDB table
resource "aws_dynamodb_table" "items" {
  name         = "fargate-items"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "pk"
  attribute {
    name = "pk"
    type = "S"
  }

  tags = {
    Project = var.project
    Env     = var.env
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

resource "aws_wafv2_web_acl_association" "alb_assoc" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.alb_waf.arn
}

# ALB 5xx rate alarm
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix }
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
