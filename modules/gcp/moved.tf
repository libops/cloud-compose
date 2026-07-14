moved {
  from = google_service_account.internal-services
  to   = google_service_account.internal-services[0]
}

moved {
  from = google_service_account_iam_member.internal-services-keys
  to   = google_service_account_iam_member.internal-services-keys[0]
}

moved {
  from = google_project_iam_member.stackdriver
  to   = google_project_iam_member.stackdriver[0]
}

moved {
  from = google_service_account_iam_member.self_jwt_signer_policy
  to   = google_service_account_iam_member.vault_agent_jwt_signer_policy[0]
}

moved {
  from = google_service_account_iam_member.app-keys
  to   = google_service_account_iam_member.app-keys[0]
}
