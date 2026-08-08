{
  schema_version: 1,
  kind: "cloud-compose.restore-test-proof",
  test_id: $test_id,
  completed_at: "2026-08-07T13:00:00Z",
  source_manifest_sha256: $manifest_sha256,
  source_receipt_sha256: $receipt_sha256,
  source_encrypted: true,
  status: "succeeded",
  recovery_id: "contract/recovery-1",
  disposable_recovery: true,
  recovery_destroyed: true,
  integrity_verified: true,
  coverage: {database: true, application_files: true, volume_topology: true}
}
