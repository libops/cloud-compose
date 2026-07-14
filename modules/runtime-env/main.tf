locals {
  # cloud-compose-env-contract: Docker Compose double-quoted dotenv data.
  # Every significant character is escaped, and profile.sh decodes the same
  # narrow grammar without evaluating the file as shell code.
  escaped_backslashes = {
    for name, value in var.env : name => replace(value, "\\", "\\\\")
  }
  escaped_quotes = {
    for name, value in local.escaped_backslashes : name => replace(value, "\"", "\\\"")
  }
  escaped_dollars = {
    for name, value in local.escaped_quotes : name => replace(value, "$", "$$")
  }
  escaped_newlines = {
    for name, value in local.escaped_dollars : name => replace(value, "\n", "\\n")
  }
  escaped_returns = {
    for name, value in local.escaped_newlines : name => replace(value, "\r", "\\r")
  }
  escaped_tabs = {
    for name, value in local.escaped_returns : name => replace(value, "\t", "\\t")
  }
  content = join("\n", [
    for name in sort(keys(var.env)) :
    "${name}=\"${local.escaped_tabs[name]}\""
  ])
}
