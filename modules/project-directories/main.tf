terraform {
  required_version = ">= 1.3.0"
}

locals {
  data_root = trimsuffix(var.data_root, "/")
  project_directories_valid = alltrue([
    for project_dir in values(var.project_dirs) :
    project_dir == trimspace(project_dir) &&
    startswith(project_dir, "${local.data_root}/") &&
    !endswith(project_dir, "/") &&
    !can(regex("//", project_dir)) &&
    !can(regex("[\\x00-\\x1f\\x7f]", project_dir)) &&
    !can(regex("(^|/)\\.\\.?(/|$)", project_dir))
  ])
}

output "project_dirs" {
  value       = var.project_dirs
  description = "Compose project directories after enforcing the managed-data ownership boundary."

  precondition {
    condition     = startswith(local.data_root, "/") && local.data_root != "/"
    error_message = "data_root must be a non-root absolute path."
  }

  precondition {
    condition     = local.project_directories_valid
    error_message = "Compose project directories must be normalized descendants of the managed data root, without whitespace padding, control characters, empty segments, trailing slashes, or dot segments."
  }
}
