variable "name" {
  type    = string
  default = "isle-example"
}

variable "project_id" {
  type = string
}

variable "project_number" {
  type = string
}

variable "docker_compose_repo" {
  type    = string
  default = "https://github.com/libops/isle"
}

variable "docker_compose_branch" {
  type    = string
  default = "main"
}

variable "ingress_port" {
  type    = number
  default = 8080
}

variable "domain" {
  type    = string
  default = ""
}

variable "acme_email" {
  type    = string
  default = ""
}

variable "enable_letsencrypt" {
  type    = bool
  default = false
}

variable "enable_bot_mitigation" {
  type    = bool
  default = false
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
