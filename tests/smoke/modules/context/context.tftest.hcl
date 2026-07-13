mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "abcdef"
    }
  }
}

variables {
  cloud_provider      = "gcp"
  template            = "wp"
  ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake cloud-compose-test"
  smoke_run_id        = "123456789"
  smoke_run_namespace = "00021i3v9"
}

run "legacy_gcp_writer" {
  command = apply

  variables {
    smoke_run_namespace = ""
  }

  assert {
    condition     = output.name == "cc-g-wp-12345678-abcd"
    error_message = "The compatibility writer must retain the legacy first-eight-character GCP name when no exact namespace is supplied."
  }
}

run "exact_archivesspace_writer" {
  command = apply

  variables {
    template = "archivesspace"
  }

  assert {
    condition     = output.name == "cc-g-as-00021i3v9-abc"
    error_message = "ArchivesSpace did not retain the exact namespace and a random suffix within the GCP name limit."
  }
}

run "exact_ojs_writer" {
  command = apply

  variables {
    template = "ojs"
  }

  assert {
    condition     = output.name == "cc-g-ojs-00021i3v9-ab"
    error_message = "OJS did not retain the exact namespace and a random suffix within the GCP name limit."
  }
}

run "exact_isle_writer" {
  command = apply

  variables {
    template = "isle"
  }

  assert {
    condition     = output.name == "cc-g-isle-00021i3v9-a"
    error_message = "ISLE did not retain the exact namespace and one random nibble within the GCP name limit."
  }
}

run "exact_drupal_writer" {
  command = apply

  variables {
    template = "drupal"
  }

  assert {
    condition     = output.name == "cc-g-dr-00021i3v9-abc"
    error_message = "Drupal did not retain the exact namespace and a random suffix within the GCP name limit."
  }
}

run "exact_wordpress_writer" {
  command = apply

  assert {
    condition     = output.name == "cc-g-wp-00021i3v9-abc"
    error_message = "WordPress did not retain the exact namespace and a random suffix within the GCP name limit."
  }

  assert {
    condition     = contains(output.tags, "gha-run-12345678") && !contains(output.tags, "gha-run-00021i3v9")
    error_message = "GCP cleanup tags must retain the legacy run-id contract while readers support both naming generations."
  }
}

run "exact_omeka_s_writer" {
  command = apply

  variables {
    template = "omeka-s"
  }

  assert {
    condition     = output.name == "cc-g-os-00021i3v9-abc"
    error_message = "Omeka S did not retain the exact namespace and a random suffix within the GCP name limit."
  }
}

run "exact_omeka_classic_writer" {
  command = apply

  variables {
    template = "omeka-classic"
  }

  assert {
    condition     = output.name == "cc-g-oc-00021i3v9-abc"
    error_message = "Omeka Classic did not retain the exact namespace and a random suffix within the GCP name limit."
  }
}

run "digitalocean_ignores_gcp_namespace" {
  command = apply

  variables {
    cloud_provider = "digitalocean"
    template       = "wp"
  }

  assert {
    condition     = output.name == "cc-do-wp-123456789-abcdef"
    error_message = "The GCP-only exact namespace changed DigitalOcean naming."
  }
}

run "linode_ignores_gcp_namespace" {
  command = apply

  variables {
    cloud_provider = "linode"
    template       = "wp"
  }

  assert {
    condition     = output.name == "cc-ln-wp-123456789-abcdef"
    error_message = "The GCP-only exact namespace changed Linode naming."
  }
}

run "invalid_exact_namespace" {
  command = plan

  variables {
    smoke_run_namespace = "12345678Z"
  }

  expect_failures = [var.smoke_run_namespace]
}

run "mismatched_exact_namespace" {
  command = plan

  variables {
    smoke_run_namespace = "00021i3v8"
  }

  expect_failures = [random_id.suffix]
}
