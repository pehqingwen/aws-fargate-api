data "aws_vpc" "main" {
  id = "vpc-02fa17267aea33220"
}

# Get all subnets in that VPC (we'll treat them as "Aurora subnets").
data "aws_subnets" "aurora_private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
}

resource "aws_db_subnet_group" "aurora" {
  name       = "${var.project}-aurora-subnets"
  subnet_ids = data.aws_subnets.aurora_private.ids

  tags = {
    Name    = "${var.project}-aurora-subnets"
    Project = var.project
    Env     = var.env
  }
}

resource "aws_security_group" "aurora" {
  name        = "${var.project}-aurora-sg"
  description = "Aurora Serverless v2"
  vpc_id      = data.aws_vpc.main.id

  # Allow Postgres only from inside the VPC
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  tags = {
    Name    = "${var.project}-aurora-sg"
    Project = var.project
    Env     = var.env
  }
}


resource "random_password" "aurora_master" {
  length  = 16
  special = false
}


resource "aws_secretsmanager_secret" "aurora" {
  name = "${var.project}-aurora-credentials"
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id = aws_secretsmanager_secret.aurora.id

  secret_string = jsonencode({
    host     = aws_rds_cluster.aurora.endpoint
    port     = aws_rds_cluster.aurora.port
    username = aws_rds_cluster.aurora.master_username
    password = random_password.aurora_master.result
    database = aws_rds_cluster.aurora.database_name
  })
}


resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.project}-aurora"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  # engine_version   = "13.6"   # <-- delete or comment this line

  database_name   = "appdb"
  master_username = "appuser"
  master_password = random_password.aurora_master.result

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  storage_encrypted = true

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 2
  }

  tags = {
    Project = var.project
    Env     = var.env
  }
}

resource "aws_rds_cluster_instance" "aurora_instance" {
  identifier         = "${var.project}-aurora-instance-1"
  cluster_identifier = aws_rds_cluster.aurora.id

  instance_class = "db.serverless"
  engine         = aws_rds_cluster.aurora.engine
  # engine_version = aws_rds_cluster.aurora.engine_version  # don't set your own

  publicly_accessible = false
}
