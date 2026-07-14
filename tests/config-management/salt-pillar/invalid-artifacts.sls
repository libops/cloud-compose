cloud_compose:
  name: invalid-artifacts
  provider: onprem
  template: wp
  dedicated_host_acknowledged: true
  install_packages: false
  reload_systemd: false
  run_bootstrap: false
  runtime:
    managed_runtime:
      artifacts:
        - name: ../unsafe-name
          url: https://example.invalid/unsafe-name
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/unsafe-name
        - name: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          url: https://example.invalid/overlong-name
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/overlong-name
        - name: unsafe-url
          url: http://example.invalid/unsafe-url
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/unsafe-url
        - name: unsafe-sha
          url: https://example.invalid/unsafe-sha
          sha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
          path: /usr/local/bin/unsafe-sha
        - name: root-path
          url: https://example.invalid/root-path
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /
        - name: relative-path
          url: https://example.invalid/relative-path
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: usr/local/bin/relative-path
        - name: dot-path
          url: https://example.invalid/dot-path
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/../bin/dot-path
        - name: empty-path-segment
          url: https://example.invalid/empty-path-segment
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr//local/bin/empty-path-segment
        - name: control-path-segment
          url: https://example.invalid/control-path-segment
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: "/usr/local/bin/bad\u007fname"
        - name: unsafe-mode
          url: https://example.invalid/unsafe-mode
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/unsafe-mode
          mode: "4755"
        - name: unsafe-owner
          url: https://example.invalid/unsafe-owner
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/unsafe-owner
          owner: root:root
        - name: unsafe-group
          url: https://example.invalid/unsafe-group
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/unsafe-group
          group: root:root
        - name: unsafe-restart
          url: https://example.invalid/unsafe-restart
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/unsafe-restart
          restart: ../docker.service
        - name: duplicate-name
          url: https://example.invalid/duplicate-name-one
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/duplicate-name-one
        - name: duplicate-name
          url: https://example.invalid/duplicate-name-two
          sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          path: /usr/local/bin/duplicate-name-two
        - name: duplicate-path-one
          url: https://example.invalid/duplicate-path-one
          sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          path: /usr/local/bin/duplicate-path
        - name: duplicate-path-two
          url: https://example.invalid/duplicate-path-two
          sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          path: /usr/local/bin/duplicate-path
