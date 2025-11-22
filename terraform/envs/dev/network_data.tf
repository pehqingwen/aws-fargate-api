# Read existing VPC created by foundation
data "aws_vpc" "this" {
  id = "vpc-02fa17267aea33220"
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["private"]
  } # or use your tags
}

# network_data.tf (already have VPC/Subnets data lookups)
data "aws_lb" "alb" {
  name = "fargate-api-alb"
}

data "aws_lb_target_group" "api" {
  name = "fargate-api-tg"
}

# Either reference an existing ECS SG created by foundation...
# data "aws_security_group" "ecs" {
#   filter { name = "group-name" values = ["fargate-api-ecs-sg"] }
#   vpc_id = data.aws_vpc.this.id
# }

# data_alb_sg.tf
data "aws_security_group" "alb" {
  id = "sg-0fac368c01fb574c0" # the real ALB SG id
}

resource "aws_security_group" "ecs" {
  name        = "${var.project}-ecs-sg"
  description = "ECS tasks" # <- match what's live to avoid replacement
  vpc_id      = data.aws_vpc.this.id

  # ALB -> tasks on port 3000
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [data.aws_security_group.alb.id] # == sg-0fac368c01fb574c0
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = var.project, Env = var.env }

  lifecycle {
    create_before_destroy = true
    # optional hardening to prevent this reappearing if AWS/provider tweaks it:
    # ignore_changes = [description]
  }
}

