import Config

if config_env() == :prod do
  System.put_env("ERL_CRASH_DUMP_BYTES", "0")
  SymphonyElixir.Paths.set_state_root_from_env()
  SymphonyElixir.Paths.set_logs_root_from_env()
end
