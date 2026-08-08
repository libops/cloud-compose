.services[].volumes[]? | select(.type == "bind") | .source
