{
  app: {
    docker_compose_repo: "https://github.com/libops/wp.git",
    docker_compose_branch: "v1.1.1",
    project_dir: $project_dir,
    compose_project_name: "app",
    sitectl_context_name: "app",
    sitectl_plugin: "wp",
    sitectl_environment: "preview",
    ingress: {},
    init_commands: [],
    up_commands: [],
    down_commands: [],
    rollout_commands: []
  }
}
