(.[$app].sitectl_verify_args // []) as $values |
if ($values | type) != "array" or any($values[];
  type != "string" or (explode | index(0) != null) or contains("\n") or contains("\r")
) then
  error("invalid verify args")
else
  $values
end
