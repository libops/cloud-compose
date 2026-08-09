.required_coverage == ["database", "application_files", "volume_topology"] and
(.applications | length == 1) and
(.applications[0].databases | length == 1) and
.applications[0].application_files.roots == [env.TEST_DATA_ROOT + "/projects/alpha"] and
.applications[0].volume_topology.declared_named_volumes == ["alpha_data"] and
(.applications[0].volume_topology.service_mounts | length == 3)
