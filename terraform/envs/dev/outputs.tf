output "ecr_repository_url" {
  value = aws_ecr_repository.repo.repository_url
}

# outputs.tf (fix references)
output "alb_dns_name" {
  value = data.aws_lb.alb.dns_name
}

output "alb_arn_suffix" {
  value = data.aws_lb.alb.arn_suffix
}

output "target_group_arn" {
  value = data.aws_lb_target_group.api.arn
}