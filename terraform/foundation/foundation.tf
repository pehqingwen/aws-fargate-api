# Bucket (must enable Object Lock at creation time)
resource "aws_s3_bucket" "audit" {
  bucket              = var.audit_bucket_name
  object_lock_enabled = true
  force_destroy       = false
  tags                = { Project = var.project, Env = var.env }
}

# Versioning (required for Object Lock)
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption (SSE-S3)
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Object Lock default retention (compliance)
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  # Ensure versioning is enabled before configuring Object Lock
  depends_on = [aws_s3_bucket_versioning.audit]

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 30
    }
  }
}


data "aws_caller_identity" "this" {}

data "aws_iam_policy_document" "audit_bucket_policy" {
  # --- CloudTrail (keep) ---
  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/AWSLogs/${data.aws_caller_identity.this.account_id}/*"]
  }
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]
  }

  # --- AWS Config (BucketOwnerEnforced: no ACL condition) ---
  # AWS Config: allow list (some accounts require this)
  statement {
    sid    = "AWSConfigListBucket"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.audit.arn]
  }

  # 2) Bucket ACL check
  statement {
    sid    = "AWSConfigBucketPermissionsCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]
  }

  # TEMP: allow Config to write anywhere in the bucket (diagnostic)
  statement {
    sid    = "AWSConfigBucketDeliveryCatchAllTEMP"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket_policy.json
}

# 2) Multi-region CloudTrail (account scope)
resource "aws_cloudtrail" "account_trail" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.audit.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = null

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.audit]
}

# Role for the recorder
data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "config_role" {
  name               = "${var.project}-config-role"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}
resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "this" {
  name     = "${var.project}-recorder"
  role_arn = aws_iam_role.config_role.arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}


# New bucket dedicated to AWS Config (unique name!)
variable "config_bucket_name" {
  type    = string
  default = "qw-config-logs-541701833637-aps1"
}

resource "aws_s3_bucket" "config_logs" {
  bucket              = var.config_bucket_name
  object_lock_enabled = false
  force_destroy       = false
}

resource "aws_s3_bucket_ownership_controls" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_versioning" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "config_logs" {
  bucket                  = aws_s3_bucket.config_logs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

# Minimal, known-good policy for AWS Config
data "aws_iam_policy_document" "config_bucket_policy" {
  # Config needs these on the bucket itself
  statement {
    sid    = "ConfigListAndLocation"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config_logs.arn]
  }

  # Allow writes to a simple, valid prefix
  statement {
    sid    = "ConfigPutToPrefix"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.config_logs.arn}/config",  # marker
      "${aws_s3_bucket.config_logs.arn}/config/*" # files
    ]
  }
}

resource "aws_s3_bucket_policy" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id
  policy = data.aws_iam_policy_document.config_bucket_policy.json
}

# Delivery channel using the new bucket + the simple prefix
resource "aws_config_delivery_channel" "this" {
  name           = "${var.project}-delivery"
  s3_bucket_name = aws_s3_bucket.config_logs.bucket
  s3_key_prefix  = "config"

  depends_on = [
    aws_s3_bucket_policy.config_logs,
    aws_config_configuration_recorder.this
  ]
}

# (Keep your existing recorder + recorder_status resources)


resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}


# A few high-value managed rules
resource "aws_config_config_rule" "cloudtrail_enabled" {
  name = "cloudtrail-enabled"
  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }
}

resource "aws_config_config_rule" "s3_versioning" {
  name = "s3-bucket-versioning-enabled"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_VERSIONING_ENABLED"
  }
}

resource "aws_config_config_rule" "restricted_ssh" {
  name = "restricted-ssh"
  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }
}

# GuardDuty
resource "aws_guardduty_detector" "this" {
  enable = true
  datasources {
    s3_logs { enable = true }
  }
}

# Security Hub
resource "aws_securityhub_account" "this" {}

# AWS Foundational Security Best Practices (v1.0.0)
resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:ap-southeast-1::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}

# CIS AWS Foundations Benchmark (pick ONE version; v5.0.0 recommended)
resource "aws_securityhub_standards_subscription" "cis_v5" {
  standards_arn = "arn:aws:securityhub:ap-southeast-1::standards/cis-aws-foundations-benchmark/v/5.0.0"
  depends_on    = [aws_securityhub_account.this]
}
# If you specifically need an earlier version, use v3.0.0 or v1.4.0:
# "arn:aws:securityhub:ap-southeast-1::standards/cis-aws-foundations-benchmark/v/3.0.0"
# "arn:aws:securityhub:ap-southeast-1::standards/cis-aws-foundations-benchmark/v/1.4.0"

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_ssm_role" {
  name               = "${var.project}-ec2-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "${var.project}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

