@{
    # Only these keys are owned.  Everything else in config.toml is local.
    Agents = @{
        enabled                           = $true
        max_concurrent_threads_per_session = 3
        default_subagent_model            = 'gpt-5.6-terra'
        default_subagent_reasoning_effort = 'medium'
    }
    ProjectTrustLevel = 'trusted'
}
