{
  schema_version: 1,
  kind: "cloud-compose.offhost-backup-manifest",
  operation_id: $operation_id,
  backup_date: $backup_date,
  provider: $provider,
  instance: $instance,
  required_coverage: ["database", "application_files", "volume_topology"],
  applications: (sort_by(.name))
}
