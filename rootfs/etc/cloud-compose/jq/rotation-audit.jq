{
  version: 1,
  phase: $phase,
  current_key_id: $current_key_id,
  new_key_id: $new_key_id,
  recovery_required: ($phase == "creating" or $phase == "creating-fresh"),
  candidate_key_ids: [$candidate_names[] | split("/")[-1]],
  created_at: $created_at,
  ready_at: $ready_at,
  disabled_at: $disabled_at,
  grace_remaining_seconds: $grace_remaining
}
