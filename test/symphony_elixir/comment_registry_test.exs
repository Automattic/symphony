defmodule SymphonyElixir.AgentTools.Linear.CommentRegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry

  test "start_link/1 with seed_ids pre-populates owned comments" do
    {:ok, pid} = CommentRegistry.start_link(seed_ids: ["c1", "c2"])

    assert CommentRegistry.owned?(pid, "c1")
    assert CommentRegistry.owned?(pid, "c2")
    refute CommentRegistry.owned?(pid, "c3")
  end

  test "start_link/1 with empty or missing seed_ids starts empty" do
    {:ok, pid_empty} = CommentRegistry.start_link(seed_ids: [])
    refute CommentRegistry.owned?(pid_empty, "c1")

    {:ok, pid_default} = CommentRegistry.start_link()
    refute CommentRegistry.owned?(pid_default, "c1")
  end

  test "start_link/1 ignores non-binary entries in seed_ids" do
    {:ok, pid} = CommentRegistry.start_link(seed_ids: ["valid", nil, 123, "also-valid"])

    assert CommentRegistry.owned?(pid, "valid")
    assert CommentRegistry.owned?(pid, "also-valid")
    refute CommentRegistry.owned?(pid, "123")
  end
end
