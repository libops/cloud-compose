select(
  .version == 2 and
  (.phase == "reconciling" or .phase == "creating-fresh" or
    .phase == "creating" or .phase == "staged" or .phase == "authenticated" or
    .phase == "ready" or .phase == "grace" or .phase == "rolling-back" or
    .phase == "rollback" or .phase == "revoke-new") and
  .service_account == $service_account and
  .project_id == $project_id and
  .credentials_file == $credentials_file and
  (.current_key_id | type == "string" and (explode | index(0) == null)) and
  (.new_key_id | type == "string" and (explode | index(0) == null)) and
  (.new_key_name | type == "string" and (explode | index(0) == null)) and
  (.baseline_key_names | type == "array") and
  (.baseline_key_names | length <= 10 and . == (sort | unique)) and
  all(.baseline_key_names[];
    type == "string" and (explode | index(0) == null)) and
  (.created_at | type == "number" and . >= 0 and floor == .) and
  (.ready_at | type == "number" and . >= 0 and floor == .) and
  (.disabled_at | type == "number" and . >= 0 and floor == .)
)
