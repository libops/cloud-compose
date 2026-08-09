{
  services: {
    web: {
      volumes: [
        {type: "bind", source: ($root + "/projects/alpha/files"), target: "/srv/files", read_only: false},
        {type: "volume", source: "alpha_data", target: "/var/lib/app", read_only: false},
        {type: "tmpfs", source: "", target: "/run/app", read_only: false}
      ]
    }
  },
  volumes: {alpha_data: {name: "alpha_data"}}
}
