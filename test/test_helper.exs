ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

System.put_env(
  "SYMPHONY_SECRET_KEY_BASE",
  System.get_env("SYMPHONY_SECRET_KEY_BASE", String.duplicate("s", 64))
)

audit_dir = Path.join(System.tmp_dir!(), "symphony-elixir-test-audit-#{System.unique_integer([:positive])}")
state_root = Path.join(System.tmp_dir!(), "symphony-elixir-test-state-#{System.unique_integer([:positive])}")
logs_root = Path.join(System.tmp_dir!(), "symphony-elixir-test-logs-#{System.unique_integer([:positive])}")
run_store_dir = Application.fetch_env!(:symphony_elixir, :run_store_dir)
mcp_socket_base = Application.fetch_env!(:symphony_elixir, :mcp_socket_base)
File.rm_rf!(mcp_socket_base)
File.mkdir_p!(mcp_socket_base)
Application.put_env(:symphony_elixir, :state_root, state_root)
Application.put_env(:symphony_elixir, :logs_root, logs_root)
Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

ExUnit.after_suite(fn _results ->
  File.rm_rf(audit_dir)
  File.rm_rf(state_root)
  File.rm_rf(logs_root)
  File.rm_rf(run_store_dir)
  File.rm_rf(mcp_socket_base)
end)
