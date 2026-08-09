type == "object" and length > 0 and
all(to_entries[]; . as $entry |
  ($entry.key | explode | index(0) == null) and
  ($entry.value | type == "object") and
  (all($entry.value | .. | select(type == "string");
    explode | index(0) == null)) and
  ($entry.value.docker_compose_repo | type == "string" and length > 0) and
  ($entry.value.docker_compose_branch | type == "string" and length > 0) and
  ($entry.value.project_dir | type == "string" and length > 0) and
  ($entry.value.compose_project_name | type == "string" and length > 0) and
  (all(["init_commands", "up_commands", "down_commands", "rollout_commands"][];
    . as $field |
    ($entry.value[$field] == null) or
    (($entry.value[$field] | type) == "array" and
      all($entry.value[$field][]; type == "string"))
  )) and
  (($entry.value.sitectl_verify_args == null) or
    (($entry.value.sitectl_verify_args | type) == "array" and
      all($entry.value.sitectl_verify_args[];
        type == "string" and
        (explode | index(0) == null) and
        (contains("\n") | not) and
        (contains("\r") | not)
      ))) and
  (($entry.value.ingress == null) or ($entry.value.ingress | type == "object"))
)
