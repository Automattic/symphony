defmodule SymphonyElixir.PlaybookCatalogTest do
  @moduledoc """
  Guards that `docs/playbook.md` stays in exact sync with the embedded partials.
  The catalog is the user-facing contract for `{% render %}`, so it must not drift
  from the `{% comment %}` headers in `priv/playbook/*.liquid`.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Playbook

  @catalog_path Path.expand(Path.join([__DIR__, "..", "..", "docs", "playbook.md"]))

  test "docs/playbook.md matches the embedded playbook partials" do
    assert from_partials() == from_catalog()
  end

  defp from_partials do
    Map.new(Playbook.partials(), fn {name, body} ->
      {name, %{description: header_value(body, "description"), vars: header_vars(body)}}
    end)
  end

  defp header_value(body, key) do
    [_, value] = Regex.run(~r/^#{key}:\s*(.+)$/m, body)
    String.trim(value)
  end

  defp header_vars(body) do
    [_, inner] = Regex.run(~r/^vars:\s*\[(.*)\]$/m, body)

    inner
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp from_catalog do
    @catalog_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^\| `[a-z_]+` \|/, &1))
    |> Map.new(&parse_catalog_row/1)
  end

  defp parse_catalog_row(row) do
    [name_cell, vars_cell, description_cell] =
      row
      |> String.split("|", trim: true)
      |> Enum.map(&String.trim/1)

    {backticked(name_cell) |> hd(), %{description: description_cell, vars: backticked(vars_cell)}}
  end

  defp backticked(cell) do
    ~r/`([^`]+)`/
    |> Regex.scan(cell)
    |> Enum.map(fn [_, value] -> value end)
  end
end
