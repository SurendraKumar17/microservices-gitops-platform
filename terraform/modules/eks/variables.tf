variable "cluster_name"    {}
variable "subnet_ids"      {}
variable "vpc_id"          {}
variable "region"          {}
variable "env"             { default = "dev" }
variable "project"         { default = "microservices" }
variable "k8s_version"     { default = "1.29" }
variable "instance_types"  { default = ["t3.medium"] }
variable "desired_size"    { default = 2 }
variable "max_size"        { default = 4 }
variable "min_size"        { default = 1 }