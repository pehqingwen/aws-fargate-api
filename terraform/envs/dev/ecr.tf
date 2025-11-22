# terraform/envs/dev/ecr.tf
resource "aws_ecr_repository" "repo" {
  name                 = "fargate-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    # ignore changes that AWS/console might adjust
    ignore_changes = [
      image_tag_mutability,
      image_scanning_configuration,
      encryption_configuration,
      tags
    ]
  }

  tags = { Project = var.project, Env = var.env }
}
