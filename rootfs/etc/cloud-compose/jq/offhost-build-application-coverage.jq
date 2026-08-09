{
  name: $app,
  databases: [{
    engine: "mariadb",
    format: "sql.gz",
    local_recovery_artifact: $dump_path,
    sha256: $dump_sha256,
    bytes: $dump_bytes
  }],
  application_files: {
    roots: [$project_dir],
    bind_mounts: [
      .services | to_entries[] as $service |
      ($service.value.volumes // [])[] |
      select(.type == "bind") |
      {service: $service.key, source: .source, target: .target, read_only: (.read_only // false)}
    ] | sort_by(.service, .source, .target)
  },
  volume_topology: {
    declared_named_volumes: ((.volumes // {}) | keys | sort),
    service_mounts: [
      .services | to_entries[] as $service |
      ($service.value.volumes // [])[] |
      {service: $service.key, type: .type, source: (.source // ""), target: .target, read_only: (.read_only // false)}
    ] | sort_by(.service, .type, .source, .target)
  }
}
