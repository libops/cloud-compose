(.[$app].ingress[$field] // "" | tostring) as $value |
if $value | (explode | index(0) != null) or contains("\n") or contains("\r") then
  error("invalid ingress scalar field")
else
  $value
end
