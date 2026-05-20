defmodule Mix.Tasks.Symphony.InitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Init

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-init-task-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  test "runs through the Mix task entrypoint", %{root: root} do
    File.cd!(root, fn ->
      output =
        capture_io(fn ->
          assert :ok = Init.run(["--team", "ENG", "--project-slug", "harness", "--agent", "codex"])
        end)

      assert output =~ "Created WORKFLOW.md and symphony.yml"
      assert File.regular?("WORKFLOW.md")
      assert File.regular?("symphony.yml")
    end)
  end

  test "raises usage errors through Mix", %{root: root} do
    File.cd!(root, fn ->
      assert_raise Mix.Error, ~r/Usage: symphony init/, fn ->
        Init.run(["unexpected"])
      end
    end)
  end

  test "raises conflict diff errors through Mix", %{root: root} do
    File.write!(Path.join(root, "WORKFLOW.md"), "old workflow\n")

    File.cd!(root, fn ->
      assert_raise Mix.Error, ~r/Refusing to overwrite existing files without --force.*-old workflow/s, fn ->
        Init.run(["--team", "ENG", "--project-slug", "harness", "--agent", "codex"])
      end
    end)
  end
end
