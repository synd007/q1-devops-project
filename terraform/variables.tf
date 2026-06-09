variable "aws_region" {
  type        = string
  default     = "eu-west-1"
  description = "region to deploy resources"
}

variable "availability_zone" {
  type        = string
  default     = "eu-west-1"
  description = "az to deploy resources"
}

variable "db_username" {
  description = "Database username"
  type        = string
  default     = "johnadmin"
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
}