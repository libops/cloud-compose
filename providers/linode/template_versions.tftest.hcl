mock_provider "linode" {}
mock_provider "http" {
  mock_data "http" {
    defaults = {
      response_body = "8cc800954d4780c933ebd680b25ec7dacfb61a733b9295f272ab56ac8fbf6b74\n"
      status_code   = 200
    }
  }
}

run "custom_package_set_merges_only_applicable_template_versions" {
  command = plan

  variables {
    name     = "template-versions"
    template = "isle"
    linode = {
      instance = {
        authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyKey cloud-compose-test"]
      }
    }
    runtime = {
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
    condition     = local.runtime.compose.branch == "v1.3.0"
    error_message = "The Linode entrypoint must inherit the ISLE v1.3.0 template branch when no override is supplied."
  }

  assert {
    condition     = local.runtime.extra_env.ISLANDORA_TAG == "6.3.19"
    error_message = "The Linode ISLE preset must supply its required application environment."
  }
}

run "explicit_core_only_package_set_disables_template_plugins" {
  command = plan

  variables {
    name     = "template-versions"
    template = "isle"
    linode = {
      instance = {
        authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyKey cloud-compose-test"]
      }
    }
    runtime = {
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
