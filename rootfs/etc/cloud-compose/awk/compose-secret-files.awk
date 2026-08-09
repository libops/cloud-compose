/^[[:space:]]*services:/ {
    in_secrets = 0
}

/^[^[:space:]][^:]*:/ {
    if ($0 ~ /^secrets:/) {
        in_secrets = 1
    } else if (in_secrets) {
        in_secrets = 0
    }
}

in_secrets && /^[[:space:]]*file:[[:space:]]*/ {
    value = $0
    sub(/^[[:space:]]*file:[[:space:]]*/, "", value)
    gsub(/^["']|["']$/, "", value)
    print value
}
