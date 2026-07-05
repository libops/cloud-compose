variable "name" {
  type    = string
  default = "wp-example"
}

variable "project_id" {
  type = string
}

variable "project_number" {
  type = string
}

variable "docker_compose_repo" {
  type    = string
  default = "https://github.com/libops/wp.git"
}

variable "docker_compose_branch" {
  type    = string
  default = "main"
}

variable "ingress_port" {
  type    = number
  default = 8080
}

variable "vault_addr" {
  type    = string
  default = ""
}

variable "vault_role" {
  type    = string
  default = ""
}

variable "vault_agent_enabled" {
  type    = bool
  default = false
}
