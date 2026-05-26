defmodule SymphonyElixir.Playbook do
  @moduledoc """
  Symphony-owned generic orchestration playbook, shipped as Solid partials that a
  repo `WORKFLOW.md` pulls in with `{% render "<name>" %}`.

  Each partial is one `priv/playbook/<name>.liquid` file (the single source of
  truth for that block of prose, so it stops drifting across repos). The bytes are
  embedded at compile time via `@external_resource` so they ride along even in
  escript builds where `priv/` is dropped, mirroring
  `SymphonyElixir.SharedSkills`. `SymphonyElixir.Playbook.FileSystem` serves them
  to Solid from the in-memory map below.
  """

  @source_root Path.expand(Path.join([__DIR__, "..", "..", "priv", "playbook"]))
  @partial_paths @source_root |> Path.join("*.liquid") |> Path.wildcard() |> Enum.sort()

  for path <- @partial_paths do
    @external_resource path
  end

  @partials (for path <- @partial_paths, into: %{} do
               {Path.basename(path, ".liquid"), File.read!(path)}
             end)

  @names @partials |> Map.keys() |> Enum.sort()

  @doc "Names of the available playbook partials, sorted."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Raw partial bodies keyed by name."
  @spec partials() :: %{String.t() => String.t()}
  def partials, do: @partials

  @doc "Fetch a partial body by name."
  @spec fetch(String.t()) :: {:ok, String.t()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@partials, name)
end
