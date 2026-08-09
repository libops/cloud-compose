{
    filename = $2
    sub(/^\*/, "", filename)
    if (filename == asset) {
        checksum = $1
        matches++
    }
}
END {
    if (matches != 1) {
        exit 1
    }
    print checksum
}
