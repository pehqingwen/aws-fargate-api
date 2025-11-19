variable "project" {
  type    = string
  default = "fargate-api"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

# Choose AZs in your region; 2 or 3 is fine.
variable "azs" {
  type    = list(string)
  default = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

# Subnet CIDRs (match the number of AZs)
variable "public_subnets" {
  type    = list(string)
  default = ["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"]
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.10.48.0/20", "10.10.64.0/20", "10.10.80.0/20"]
}

variable "audit_bucket_name" {
  type    = string
  default = "qw-audit-logs-541701833637-aps1"
}
