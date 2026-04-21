variable "region"      {}
variable "cidr"        {}
variable "env"         {}
variable "azs" {
  type = list(string)
}
variable "project" {
  default = "microservices"
}