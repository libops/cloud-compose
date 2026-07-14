variable "project_dirs" {
  type        = map(string)
  description = "Normalized Compose project directories keyed by application name."
}

variable "data_root" {
  type        = string
  default     = "/mnt/disks/data"
  description = "Exclusive host ownership boundary for Compose project directories."
}
