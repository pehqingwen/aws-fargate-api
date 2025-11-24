resource "aws_ecs_cluster" "this" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Project = var.project, Env = var.env }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.cpu
  memory                   = local.memory

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task_role.arn

  # Optional: Fargate defaults are Linux/x86_64; keep if you prefer explicitness
  # runtime_platform {
  #   operating_system_family = "LINUX"
  #   cpu_architecture        = "X86_64"
  # }

  container_definitions = jsonencode([
    {
      name = local.container_name
      # ✅ Use the ECR **resource** (since you manage the repo in Terraform)
      image = var.image != "" ? var.image : "${aws_ecr_repository.repo.repository_url}:latest"

      essential    = true
      portMappings = [{ containerPort = local.container_port, protocol = "tcp" }]

      environment = [
        { name = "PORT", value = tostring(local.container_port) },
        { name = "NODE_OPTIONS", value = "--max-old-space-size=256" },
        { name = "ITEMS_TABLE_NAME", value = aws_dynamodb_table.items.name },
        {
          name  = "DB_HOST"
          value = aws_rds_cluster.aurora.endpoint
        },
        {
          name  = "DB_PORT"
          value = tostring(aws_rds_cluster.aurora.port)
        },
        {
          name  = "DB_NAME"
          value = aws_rds_cluster.aurora.database_name
        },
        {
          name  = "DB_USER"
          value = aws_rds_cluster.aurora.master_username
        },
        {
          name  = "DB_PASSWORD"
          value = random_password.aurora_master.result
        }
      ]

      # Soft + hard memory (reservation <= memory)
      memoryReservation = 384
      memory            = 512

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS http://localhost:${local.container_port}/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])

  tags = { Project = var.project, Env = var.env }
}

resource "aws_ecs_service" "api" {
  name            = "${var.project}-svc"
  cluster         = aws_ecs_cluster.this.id
  launch_type     = "FARGATE"
  desired_count   = 1
  task_definition = aws_ecs_task_definition.api.arn

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = data.aws_lb_target_group.api.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  propagate_tags = "SERVICE"
  tags           = { Project = var.project, Env = var.env }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count]
  }
}
