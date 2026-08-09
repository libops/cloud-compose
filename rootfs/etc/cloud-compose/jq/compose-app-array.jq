(.[$app][$field] // []) as $values |
if ($values | type) != "array" or any($values[]; type != "string") then
  error("invalid string array")
else
  $values
end
