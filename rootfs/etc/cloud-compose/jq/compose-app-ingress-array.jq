(.[$app].ingress[$field] // []) as $values |
if ($values | type) != "array" or any($values[]; type != "string") then
  error("invalid ingress string array")
else
  $values
end
