defmodule SymphonyElixir.ProjectGuidesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.ProjectGuides

  test "reads present guides and skips missing guides" do
    workspace = tmp_workspace!("project-guides-read")

    try do
      File.write!(Path.join(workspace, "CLAUDE.md"), "Claude rules\n")

      assert {:ok, [%{path: "CLAUDE.md", content: "Claude rules\n"}]} =
               ProjectGuides.read(workspace, ["CLAUDE.md"])

      assert {:ok, []} = ProjectGuides.read(workspace, ["MISSING.md"])
      assert ProjectGuides.prompt_section([]) == nil
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects path escapes" do
    workspace = tmp_workspace!("project-guides-paths")

    try do
      assert {:error, :path_escape} = ProjectGuides.read(workspace, ["../outside.md"])
      assert {:error, :path_escape} = ProjectGuides.read(workspace, ["/tmp/outside.md"])
      assert {:error, :path_escape} = ProjectGuides.read(workspace, ["@bad\n.md"])
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects size and utf8 violations" do
    workspace = tmp_workspace!("project-guides-size")

    try do
      File.write!(Path.join(workspace, "CLAUDE.md"), "12345")

      assert {:error, {:project_guide_file_too_large, "CLAUDE.md"}} =
               ProjectGuides.read(workspace, ["CLAUDE.md"], per_file_bytes: 4)

      File.write!(Path.join(workspace, "A.md"), "67890")
      File.write!(Path.join(workspace, "CLAUDE.md"), "@A.md\n12345")

      assert {:error, :project_guide_total_size_exceeded} =
               ProjectGuides.read(workspace, ["CLAUDE.md"], total_bytes: 8)

      File.write!(Path.join(workspace, "BAD.md"), <<0xFF, 0xFE>>)

      assert {:error, {:project_guide_invalid_utf8, "BAD.md"}} =
               ProjectGuides.read(workspace, ["BAD.md"])
    after
      File.rm_rf(workspace)
    end
  end

  test "resolves imports recursively under subheadings" do
    workspace = tmp_workspace!("project-guides-import")

    try do
      File.write!(Path.join(workspace, "CLAUDE.md"), "Claude\n@AGENTS.md\n")
      File.write!(Path.join(workspace, "AGENTS.md"), "Agents\n@docs/RULES.md\n")
      File.mkdir_p!(Path.join(workspace, "docs"))
      File.write!(Path.join(workspace, "docs/RULES.md"), "Nested\n")

      assert {:ok, [%{content: content}]} = ProjectGuides.read(workspace, ["CLAUDE.md"])

      assert content =~ "Claude"
      assert content =~ "### @AGENTS.md"
      assert content =~ "Agents"
      assert content =~ "### @docs/RULES.md"
      assert content =~ "Nested"
    after
      File.rm_rf(workspace)
    end
  end

  test "skips recursive imports and logs the skipped path" do
    workspace = tmp_workspace!("project-guides-cycle")

    try do
      File.write!(Path.join(workspace, "CLAUDE.md"), "Claude\n@A.md\n")
      File.write!(Path.join(workspace, "A.md"), "A\n@CLAUDE.md\n")

      log =
        capture_log(fn ->
          assert {:ok, [%{content: content}]} = ProjectGuides.read(workspace, ["CLAUDE.md"])
          assert content =~ "### @A.md"
          assert content =~ "### @CLAUDE.md"
        end)

      assert log =~ "Skipping recursive project guide import path=CLAUDE.md"
    after
      File.rm_rf(workspace)
    end
  end

  test "enforces depth and file-count caps" do
    workspace = tmp_workspace!("project-guides-caps")

    try do
      for index <- 0..4 do
        next = index + 1
        body = if index == 4, do: "done\n", else: "@F#{next}.md\n"
        File.write!(Path.join(workspace, "F#{index}.md"), body)
      end

      assert {:error, {:project_guide_depth_exceeded, "F3.md"}} =
               ProjectGuides.read(workspace, ["F0.md"], max_depth: 2)

      assert {:error, :project_guide_file_count_exceeded} =
               ProjectGuides.read(workspace, ["F0.md"], max_files: 2)
    after
      File.rm_rf(workspace)
    end
  end

  test "rejects unsafe import targets" do
    workspace = tmp_workspace!("project-guides-import-paths")

    try do
      for target <- ["@~/foo", "@/tmp/foo", "@../outside"] do
        File.write!(Path.join(workspace, "CLAUDE.md"), target <> "\n")
        assert {:error, :path_escape} = ProjectGuides.read(workspace, ["CLAUDE.md"])
      end
    after
      File.rm_rf(workspace)
    end
  end

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end
end
