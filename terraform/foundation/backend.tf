terraform {
  backend "s3" {
    bucket         = "qw-tf-states-541701833637"
    key            = "foundation/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "qw-tf-locks"
    encrypt        = true
  }
}
