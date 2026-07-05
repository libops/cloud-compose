moved {
  from = time_static.snapshot_time_static
  to   = module.gcp.time_static.snapshot_time_static
}

moved {
  from = google_service_account.cloud-compose
  to   = module.gcp.google_service_account.cloud-compose
}

moved {
  from = google_artifact_registry_repository_iam_member.private-policy-cloud-compose
  to   = module.gcp.google_artifact_registry_repository_iam_member.private-policy-cloud-compose
}

moved {
  from = google_service_account_iam_member.gsa-user
  to   = module.gcp.google_service_account_iam_member.gsa-user
}

moved {
  from = google_service_account_iam_member.token-creator
  to   = module.gcp.google_service_account_iam_member.token-creator
}

moved {
  from = google_project_iam_member.log
  to   = module.gcp.google_project_iam_member.log
}

moved {
  from = google_compute_disk.boot
  to   = module.gcp.google_compute_disk.boot
}

moved {
  from = google_compute_disk.data
  to   = module.gcp.google_compute_disk.data
}

moved {
  from = google_compute_disk.docker-volumes
  to   = module.gcp.google_compute_disk.docker-volumes
}

moved {
  from = google_compute_reservation.production
  to   = module.gcp.google_compute_reservation.production
}

moved {
  from = google_compute_resource_policy.daily_snapshot
  to   = module.gcp.google_compute_resource_policy.daily_snapshot
}

moved {
  from = google_compute_resource_policy.weekly_snapshot
  to   = module.gcp.google_compute_resource_policy.weekly_snapshot
}

moved {
  from = google_compute_disk_resource_policy_attachment.daily_snapshot
  to   = module.gcp.google_compute_disk_resource_policy_attachment.daily_snapshot
}

moved {
  from = google_compute_disk_resource_policy_attachment.weekly_snapshot
  to   = module.gcp.google_compute_disk_resource_policy_attachment.weekly_snapshot
}

moved {
  from = google_compute_disk.overlay_disk
  to   = module.gcp.google_compute_disk.overlay_disk
}

moved {
  from = google_compute_instance.cloud-compose
  to   = module.gcp.google_compute_instance.cloud-compose
}

moved {
  from = google_service_account.internal-services
  to   = module.gcp.google_service_account.internal-services
}

moved {
  from = google_service_account_iam_member.internal-services-keys
  to   = module.gcp.google_service_account_iam_member.internal-services-keys
}

moved {
  from = google_project_iam_member.stackdriver
  to   = module.gcp.google_project_iam_member.stackdriver
}

moved {
  from = google_project_iam_member.gce-suspend
  to   = module.gcp.google_project_iam_member.gce-suspend
}

moved {
  from = google_service_account.app
  to   = module.gcp.google_service_account.app
}

moved {
  from = google_service_account_iam_member.app-keys
  to   = module.gcp.google_service_account_iam_member.app-keys
}

moved {
  from = google_service_account_iam_member.self_jwt_signer_policy
  to   = module.gcp.google_service_account_iam_member.self_jwt_signer_policy
}

moved {
  from = google_service_account.ppb
  to   = module.gcp.google_service_account.ppb
}

moved {
  from = module.ppb
  to   = module.gcp.module.ppb
}

moved {
  from = google_project_iam_member.gce-start
  to   = module.gcp.google_project_iam_member.gce-start
}

moved {
  from = google_compute_firewall.allow_ssh_ipv4
  to   = module.gcp.google_compute_firewall.allow_ssh_ipv4
}

moved {
  from = google_compute_firewall.allow_ssh_ipv6
  to   = module.gcp.google_compute_firewall.allow_ssh_ipv6
}

moved {
  from = google_compute_firewall.allow_rollout_ipv4
  to   = module.gcp.google_compute_firewall.allow_rollout_ipv4
}
