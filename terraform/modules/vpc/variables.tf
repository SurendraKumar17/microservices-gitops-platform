variable "region" {}
variable "cidr" {}
variable "azs" {
  type = list(string)
}
variable "env" {}