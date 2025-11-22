# Execution role (pull image + write logs)
data "aws_iam_policy_document" "task_exec_assume" {
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
  assume_role_policy = data.aws_iam_policy_document.task_exec_assume.json
  tags               = { Project = var.project, Env = var.env }
}

resource "aws_iam_role_policy_attachment" "task_exec_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role (app runtime). Add Dynamo perms if you use DynamoDB.
data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "task_role" {
  name               = "${var.project}-ecsTaskRole"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = { Project = var.project, Env = var.env }
}
