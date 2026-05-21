defmodule SymphonyElixir.TestSocketBase do
  @moduledoc false

  def prepare!(base, project_root \\ File.cwd!()) do
    expanded_base = validate!(base, project_root)

    File.rm_rf!(expanded_base)
    File.mkdir_p!(expanded_base)

    expanded_base
  end

  def cleanup(base, project_root \\ File.cwd!()) do
    base
    |> validate!(project_root)
    |> File.rm_rf()
  end

  def validate!(base, project_root \\ File.cwd!())

  def validate!(base, project_root) when is_binary(base) and base != "" do
    expanded_base = Path.expand(base, project_root)
    test_build_root = Path.expand("_build/test", project_root)

    if path_descendant?(expanded_base, test_build_root) do
      expanded_base
    else
      raise ArgumentError,
            "test MCP socket base must be inside _build/test; got #{inspect(base)}"
    end
  end

  def validate!(base, _project_root) do
    raise ArgumentError, "test MCP socket base must be a non-empty path; got #{inspect(base)}"
  end

  defp path_descendant?(path, parent) do
    path != parent and String.starts_with?(path, parent <> "/")
  end
end
