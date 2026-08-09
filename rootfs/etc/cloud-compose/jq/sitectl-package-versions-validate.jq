type == "object" and
all(to_entries[];
  (.key | explode | index(0) == null) and
  (.value | type == "string") and
  (.value | explode | index(0) == null)
)
