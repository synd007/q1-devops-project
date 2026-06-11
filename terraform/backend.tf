terraform {
  backend "s3" {
    bucket  = "my-devops-project-010"
    key     = "q1-devops-project/terraform.tfstate"
    region  = "eu-west-1"
    encrypt = true
  }
}