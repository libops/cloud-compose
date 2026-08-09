mock_provider "linode" {}

run "custom_package_set_merges_only_applicable_template_versions" {
  command = plan

  override_data {
    target = module.linode.module.runtime.data.http.rootfs_contract[0]
    values = {
      response_body = "c71bcb8a431176c641eaded5a8a9d8f36d76ea3ad3d709f8b6d2b3eaa12c7cb0\n"
      status_code   = 200
    }
  }

  variables {
    name     = "template-versions"
    template = "isle"
    linode = {
      instance = {
        authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyKey cloud-compose-test"]
      }
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose-rootfs.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = ["sitectl", "sitectl-wp"]
        package_versions = {
          sitectl    = "v0.40.0"
          sitectl-wp = "v0.5.1"
        }
      }
    }
  }

  assert {
    condition = local.runtime.sitectl.package_versions == {
      sitectl    = "v0.40.0"
      sitectl-wp = "v0.5.1"
    }
    error_message = "The Linode entrypoint must filter template selectors and preserve explicit overrides."
  }

  assert {
    condition     = local.runtime.compose.branch == "v1.3.1"
    error_message = "The Linode entrypoint must inherit the ISLE v1.3.1 template branch when no override is supplied."
  }

  assert {
    condition     = local.runtime.extra_env.ISLANDORA_TAG == "6.3.19"
    error_message = "The Linode ISLE preset must supply its required application environment."
  }
}

run "explicit_core_only_package_set_disables_template_plugins" {
  command = plan

  override_data {
    target = module.linode.module.runtime.data.http.rootfs_contract[0]
    values = {
      response_body = "c71bcb8a431176c641eaded5a8a9d8f36d76ea3ad3d709f8b6d2b3eaa12c7cb0\n"
      status_code   = 200
    }
  }

  variables {
    name     = "template-versions"
    template = "isle"
    linode = {
      instance = {
        authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyKey cloud-compose-test"]
      }
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose-rootfs.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = []
      }
    }
  }

  assert {
    condition = local.runtime.sitectl.packages == tolist(["sitectl"]) && local.runtime.sitectl.package_versions == {
      sitectl = "v1.8.2"
    }
    error_message = "The Linode entrypoint must preserve an explicit core-only package set."
  }
}
