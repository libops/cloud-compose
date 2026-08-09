.type == "service_account" and
.private_key_id == $key_id and
.client_email == $service_account and
.project_id == $project_id and
.token_uri == "https://oauth2.googleapis.com/token" and
(.private_key | type == "string" and
  startswith("-----BEGIN PRIVATE KEY-----") and
  contains("-----END PRIVATE KEY-----"))
