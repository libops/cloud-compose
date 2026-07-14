run "accepts_safe_artifact" {
  command = plan

  variables {
    artifacts = [{
      name    = "rollout-agent"
      url     = "https://github.com/libops/example/releases/download/v1.2.3/rollout-agent"
      sha256  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      path    = "/usr/local/bin/rollout-agent"
      mode    = "0750"
      owner   = "root"
      group   = "root"
      restart = "cloud-compose-rollout.service"
    }]
  }
}

run "rejects_unsafe_artifact_fields" {
  command = plan

  variables {
    artifacts = [{
      name    = "../escape"
      url     = "http://example.invalid/agent"
      sha256  = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      path    = "/usr/local/../etc/agent"
      mode    = "4777"
      owner   = "root:root"
      group   = "root"
      restart = "../../docker.service"
    }]
  }

  expect_failures = [output.artifacts]
}

run "rejects_root_target" {
  command = plan

  variables {
    artifacts = [{
      name   = "agent"
      url    = "https://example.invalid/agent"
      sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      path   = "/"
    }]
  }

  expect_failures = [output.artifacts]
}

run "rejects_duplicate_names_and_paths" {
  command = plan

  variables {
    artifacts = [
      {
        name   = "agent"
        url    = "https://example.invalid/agent-one"
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        path   = "/usr/local/bin/agent-one"
      },
      {
        name   = "agent"
        url    = "https://example.invalid/agent-two"
        sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        path   = "/usr/local/bin/agent-one"
      },
    ]
  }

  expect_failures = [output.artifacts]
}
