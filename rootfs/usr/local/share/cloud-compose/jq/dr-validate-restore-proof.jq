type == "object" and length == 13 and
.schema_version == 1 and
.kind == "cloud-compose.restore-test-proof" and
.test_id == $test_id and
.source_manifest_sha256 == $manifest_sha256 and
.source_receipt_sha256 == $receipt_sha256 and
.status == "succeeded" and
.disposable_recovery == true and
.recovery_destroyed == true and
.integrity_verified == true and
(.completed_at | type == "string" and length == 20 and
  (explode | all(.[]; . >= 32 and . != 127))) and
(.recovery_id | type == "string" and length >= 1 and length <= 512 and
  (explode | all(.[]; . >= 32 and . != 127))) and
(.coverage | type == "object" and length == 3 and
  .database == true and
  .application_files == true and
  .volume_topology == true) and
(.source_encrypted == true)
