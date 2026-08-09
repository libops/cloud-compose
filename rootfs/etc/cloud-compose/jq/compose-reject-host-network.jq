any(.services[];
  (.network_mode // "") == "host" or
  (
    (.build | type) == "object" and
    (
      (.build.network // "") == "host" or
      any((.build.entitlements // [])[];
        . == "network.host" or . == "security.insecure"
      )
    )
  )
)
