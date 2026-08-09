(.[$app].sitectl_verify_args // []) as $values |
if ($values | type) != "array" or any($values[]; type != "string") then
  error("invalid verify args")
else
  $values | join(" ")
end
