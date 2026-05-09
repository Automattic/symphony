ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

System.put_env(
  "SYMPHONY_SECRET_KEY_BASE",
  System.get_env("SYMPHONY_SECRET_KEY_BASE", String.duplicate("s", 64))
)

audit_dir = Path.join(System.tmp_dir!(), "symphony-elixir-test-audit-#{System.unique_integer([:positive])}")
run_store_dir = Application.fetch_env!(:symphony_elixir, :run_store_dir)
Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

ExUnit.after_suite(fn _results ->
  File.rm_rf(audit_dir)
  File.rm_rf(run_store_dir)
end)
