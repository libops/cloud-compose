(.tag_name | select(type == "string" and length > 0 and (explode | index(0) == null))),
"\u001f"
