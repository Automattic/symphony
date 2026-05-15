defmodule SymphonyElixir.AgentLabels do
  @moduledoc """
  Human-facing labels derived from the configured agent kind.
  """

  @known_kinds ["codex", "claude"]

  @type agent_context :: %{
          required(:kind) => String.t() | nil,
          required(:display_name) => String.t(),
          required(:update_label) => String.t(),
          required(:workpad_heading) => String.t()
        }

  @spec display_name(String.t() | atom() | nil) :: String.t()
  def display_name(kind) do
    case normalize_kind(kind) do
      "codex" -> "Codex"
      "claude" -> "Claude"
      _ -> "Agent"
    end
  end

  @spec update_label(String.t() | atom() | nil) :: String.t()
  def update_label(kind), do: "#{display_name(kind)} update"

  @spec workpad_heading(String.t() | atom() | nil) :: String.t()
  def workpad_heading(kind), do: "## #{display_name(kind)} Workpad"

  @spec known_workpad_markers() :: [String.t()]
  def known_workpad_markers, do: Enum.map(@known_kinds, &workpad_heading/1)

  @spec prompt_context(String.t() | atom() | nil) :: agent_context()
  def prompt_context(kind) do
    normalized_kind = normalize_kind(kind)

    %{
      kind: normalized_kind,
      display_name: display_name(normalized_kind),
      update_label: update_label(normalized_kind),
      workpad_heading: workpad_heading(normalized_kind)
    }
  end

  @spec normalize_kind(String.t() | atom() | nil) :: String.t() | nil
  def normalize_kind(nil), do: nil

  def normalize_kind(kind) when is_atom(kind), do: kind |> Atom.to_string() |> normalize_kind()

  def normalize_kind(kind) when is_binary(kind) do
    case kind |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_kind(_kind), do: nil
end
