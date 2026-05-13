import Config

if config_env() == :prod do
  SymphonyElixir.Paths.set_state_root_from_env()
  SymphonyElixir.Paths.set_logs_root_from_env()
end
