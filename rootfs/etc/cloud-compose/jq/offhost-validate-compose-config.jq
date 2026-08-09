type == "object" and
(.services | type == "object" and length > 0) and
all(.services | to_entries[];
  ((.value.volumes // []) | type == "array") and
  all((.value.volumes // [])[];
    type == "object" and
    (.type | type == "string") and
    (.type == "volume" or .type == "bind" or .type == "tmpfs") and
    ((.source // "") | type == "string") and
    ((.target // "") | type == "string" and length > 0))) and
((.volumes // {}) | type == "object")
