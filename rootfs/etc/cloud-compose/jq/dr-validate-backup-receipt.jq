type == "object" and length == 10 and
.schema_version == 1 and
.kind == "cloud-compose.offhost-backup-receipt" and
.operation_id == $operation_id and
.manifest_sha256 == $manifest_sha256 and
.status == "succeeded" and
.encrypted == true and
.off_host == true and
(.completed_at | type == "string" and length == 20 and
  (explode | all(.[]; . >= 32 and . != 127))) and
(.remote_id | type == "string" and length >= 1 and length <= 512 and
  (explode | all(.[]; . >= 32 and . != 127))) and
(.coverage | type == "object" and length == 3 and
  .database == true and
  .application_files == true and
  .volume_topology == true)
