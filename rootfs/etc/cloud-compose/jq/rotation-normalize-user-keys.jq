(.keys // []) as $keys |
if ($keys | type) != "array" then error("invalid key list") else
  [$keys[] | select(.keyType == "USER_MANAGED")] as $user_keys |
  if ($user_keys | length) > 10 then error("too many user-managed keys")
  elif any($user_keys[];
    (.name | type) != "string" or
    (.name | startswith($prefix) | not) or
    ((.disabled // false) | type) != "boolean")
  then error("invalid user-managed key")
  elif ([$user_keys[].name] | unique | length) != ($user_keys | length)
  then error("duplicate user-managed key")
  else
    [$user_keys[] | {name: .name, disabled: (.disabled // false)}] | sort_by(.name)
  end
end
