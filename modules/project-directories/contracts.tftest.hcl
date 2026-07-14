run "accepts_managed_descendants" {
  command = plan

  variables {
    project_dirs = {
      wp   = "/mnt/disks/data/libops/wp/main"
      isle = "/mnt/disks/data/libops/isle/v2"
    }
  }
}

run "rejects_host_paths_and_traversal" {
  command = plan

  variables {
    project_dirs = {
      root      = "/"
      etc       = "/etc"
      traversal = "/mnt/disks/data/../etc"
    }
  }

  expect_failures = [output.project_dirs]
}

run "rejects_ambiguous_segments" {
  command = plan

  variables {
    project_dirs = {
      duplicate_separator = "/mnt/disks/data/libops//wp"
      trailing_separator  = "/mnt/disks/data/libops/wp/"
      padded              = " /mnt/disks/data/libops/wp"
    }
  }

  expect_failures = [output.project_dirs]
}
