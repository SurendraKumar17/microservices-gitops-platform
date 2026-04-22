terraform {
  backend "s3" {
    bucket         = "surendra-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"           # ✅ updated
    dynamodb_table = "terraform-lock"
    encrypt        = true
  }
}