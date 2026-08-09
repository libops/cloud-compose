{
  app: {
    docker_compose_repo: "https://github.com/libops/wp.git",
    docker_compose_branch: "main",
    project_dir: $project_dir,
    compose_project_name: "app",
    sitectl_context_name: "app",
    sitectl_environment: "preview",
    sitectl_verify_args: ["--label", "value with spaces"],
    up_commands: [$up_program],
    init_commands: [],
    down_commands: [],
    rollout_commands: []
  }
}
