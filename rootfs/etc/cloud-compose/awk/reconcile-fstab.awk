$0 == begin { managed = 1; next }
$0 == end { managed = 0; next }
!managed {
    if (data_provider_mount != "" && $2 == data_provider_mount) {
        if ($1 == data_device) next
        conflict = 1
    }
    if (volumes_provider_mount != "" && $2 == volumes_provider_mount) {
        if ($1 == volumes_device) next
        conflict = 1
    }
    if ($2 == "/mnt/disks/data" ||
        $2 == "/mnt/disks/volumes" ||
        $2 == "/mnt/disks/data/docker/volumes" ||
        $2 == "/mnt/disks/prod-readonly") {
        conflict = 1
    }
    print
}
END { if (managed || conflict) exit 42 }
