.schema_version == 1 and
.kind == "cloud-compose.offhost-backup-manifest" and
(.applications | type == "array" and length == $app_count) and
all(.applications[];
  (.name | type == "string" and length >= 1 and length <= 63 and
    (explode | all(.[]; . >= 32 and . != 127))) and
  (.databases | length == 1) and
  (.databases[0].sha256 | type == "string" and length == 64 and
    (explode | all(.[]; . >= 32 and . != 127))) and
  (.databases[0].bytes | type == "number" and . > 0) and
  (.application_files.roots | type == "array" and length > 0) and
  (.application_files.bind_mounts | type == "array") and
  (.volume_topology.declared_named_volumes | type == "array") and
  (.volume_topology.service_mounts | type == "array"))
