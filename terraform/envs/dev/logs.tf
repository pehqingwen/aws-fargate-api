resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project}"
  retention_in_days = 14
  tags              = { Project = var.project, Env = var.env }
  lifecycle {
    prevent_destroy = true
  }
}