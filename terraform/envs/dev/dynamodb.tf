resource "aws_dynamodb_table" "items" {
  name         = "${var.project}-items"   # e.g. "fargate-api-items"
  billing_mode = "PAY_PER_REQUEST"        # on-demand, no capacity planning

  hash_key = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Project = var.project
    Env     = var.env
  }
}
