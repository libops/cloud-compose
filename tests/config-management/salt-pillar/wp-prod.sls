cloud_compose:
  name: wp-prod
  provider: onprem
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  dedicated_host_acknowledged: true
  managed_runtime_enabled: true
  internal_services_enabled: true
  internal_services_auto_update: true
  template: wp
  runtime:
    disaster_recovery:
      required: false
      driver_path: /usr/local/libexec/cloud-compose/salt-offhost
    extra_env:
      BASH_ENV: /tmp/cloud-compose-salt-untrusted-bash-env
      LD_PRELOAD: /tmp/cloud-compose-salt-untrusted-preload.so
      PORT: "9999"
      CONTRACT_BACKTICKS: '`touch /tmp/cloud-compose-salt-backtick-injection`'
      CONTRACT_BACKSLASH: "a\\path\\ends\\"
      CONTRACT_COMMAND_SUB: '$(touch /tmp/cloud-compose-salt-command-injection)'
      CONTRACT_DOLLARS: '$HOME ${HOME}'
      CONTRACT_QUOTES: 'a "double" and a single quote: O''Reilly'
      CONTRACT_WHITESPACE: '  leading and trailing  '
      CONTRACT_MULTILINE: |-
        line one
        line two
    compose:
      init: []
      up:
        - global-up-command
      down:
        - global-down-command
      rollout:
        - global-rollout-command
      ingress:
        domain: wp.example.edu
        acme_email: admin@example.edu
      projects:
        wp-prod:
          docker_compose_repo: https://github.com/libops/wp.git
          docker_compose_up: []
          docker_compose_down:
            - app-down-command
    sitectl:
      environment: production
      package_versions:
        sitectl: v1.0.0
        sitectl-wp: v1.0.0
    managed_runtime:
      enabled: false
      internal_services_enabled: false
      internal_services_auto_update: false
      artifacts:
        - name: contract-agent
          url: https://example.invalid/contract-agent
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/contract-agent
          mode: "0750"
          owner: root
          group: root
          restart: cloud-compose.service
