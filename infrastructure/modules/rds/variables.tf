variable "env"            { type = string }
variable "project"        { type = string }
variable "vpc_id"         { type = string }
variable "vpc_cidr"       { type = string }
variable "subnet_ids"     { type = list(string) }

variable "db_name" {
  type    = string
  default = "bookingdb"
}

variable "db_username" {
  type    = string
  default = "bookinguser"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}