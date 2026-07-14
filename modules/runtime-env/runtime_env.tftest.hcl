run "renders_values_as_literal_data" {
  command = plan

  variables {
    env = {
      BACKTICKS     = "`touch /tmp/cloud-compose-backtick-injection`"
      BACKSLASH     = "a\\path\\with\\slashes"
      COMMAND_SUB   = "$(touch /tmp/cloud-compose-command-injection)"
      DOLLAR_VALUE  = "$HOME $${HOME}"
      DOUBLE_QUOTES = "a \"quoted\" value"
      MULTILINE     = "line one\nline two"
      SINGLE_QUOTE  = "O'Reilly"
      SITECTL_PACKAGE_VERSIONS = jsonencode({
        sitectl      = "v0.38.0"
        sitectl-isle = "v0.12.0"
      })
      TRAILING_SLASH = "ends\\"
      WHITESPACE     = "  leading and trailing  "
    }
  }

  assert {
    condition     = strcontains(output.content, "BACKTICKS=\"`touch /tmp/cloud-compose-backtick-injection`\"")
    error_message = "Backticks must remain literal dotenv data."
  }

  assert {
    condition     = strcontains(output.content, "BACKSLASH=\"a\\\\path\\\\with\\\\slashes\"")
    error_message = "Backslashes must use the Docker Compose double-quote escape."
  }

  assert {
    condition     = strcontains(output.content, "COMMAND_SUB=\"$$(touch /tmp/cloud-compose-command-injection)\"")
    error_message = "Command substitutions must remain literal dotenv data."
  }

  assert {
    condition     = strcontains(output.content, "DOLLAR_VALUE=\"$$HOME $$${HOME}\"")
    error_message = "Dollar-prefixed values must not be interpolated by Docker Compose."
  }

  assert {
    condition     = strcontains(output.content, "DOUBLE_QUOTES=\"a \\\"quoted\\\" value\"")
    error_message = "Double quotes must use the Docker Compose escape."
  }

  assert {
    condition     = strcontains(output.content, "MULTILINE=\"line one\\nline two\"")
    error_message = "Multiline values must use the Docker Compose newline escape."
  }

  assert {
    condition     = strcontains(output.content, "SINGLE_QUOTE=\"O'Reilly\"")
    error_message = "Single quotes must remain literal dotenv data."
  }

  assert {
    condition     = strcontains(output.content, "SITECTL_PACKAGE_VERSIONS=\"{\\\"sitectl\\\":\\\"v0.38.0\\\",\\\"sitectl-isle\\\":\\\"v0.12.0\\\"}\"")
    error_message = "Structured sitectl package versions must remain valid JSON after dotenv encoding."
  }

  assert {
    condition     = strcontains(output.content, "TRAILING_SLASH=\"ends\\\\\"")
    error_message = "A trailing backslash must round-trip through Docker Compose."
  }

  assert {
    condition     = strcontains(output.content, "WHITESPACE=\"  leading and trailing  \"")
    error_message = "Leading and trailing whitespace must be preserved."
  }
}

run "rejects_invalid_environment_names" {
  command = plan

  variables {
    env = {
      "BAD-NAME" = "value"
    }
  }

  expect_failures = [var.env]
}
