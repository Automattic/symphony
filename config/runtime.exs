import Config

if config_env() == :prod do
  System.put_env("ERL_CRASH_DUMP_BYTES", "0")
  SymphonyElixir.Paths.set_state_root_from_env()
  SymphonyElixir.Paths.set_logs_root_from_env()
  # The Burrito binary boots the BEAM directly and never sources rel/env.sh, so
  # apply the same secure distribution cookie here (state root must be resolved
  # first). Harmless no-op under bin/symphony, which already set it from env.sh.
  SymphonyElixir.ReleaseCookie.apply!()
end
