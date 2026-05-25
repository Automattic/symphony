import Config

if config_env() == :prod do
  System.put_env("ERL_CRASH_DUMP_BYTES", "0")
  SymphonyElixir.Paths.set_state_root_from_env()
  SymphonyElixir.Paths.set_logs_root_from_env()
  # The Burrito binary boots the BEAM directly and never sources rel/env.sh, so
  # apply the same secure distribution cookie here (state root must be resolved
  # first). Resolving always runs so a bad cookie fails the boot; the cookie is
  # only set on a distributed node (setting one on nonode@nohost raises). This is
  # a harmless no-op under bin/symphony, which already set it from env.sh.
  cookie = SymphonyElixir.ReleaseCookie.resolve!()
  if Node.alive?(), do: :erlang.set_cookie(node(), String.to_atom(cookie))
end
