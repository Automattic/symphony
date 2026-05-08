ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

audit_dir = Path.join(System.tmp_dir!(), "symphony-elixir-test-audit-#{System.unique_integer([:positive])}")
Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)
ExUnit.after_suite(fn _results -> File.rm_rf(audit_dir) end)
