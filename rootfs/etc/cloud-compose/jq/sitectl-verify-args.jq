if type == "array" and all(.[]; type == "string") then
  .[] | ("x" + @base64)
else
  error("sitectl verify arguments must be an array of strings")
end
