defmodule SymphonyElixir.Config.RepoWorkflowSchema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema

  @primary_key false
  @allowed_keys ~w(hooks verification validation)

  embedded_schema do
    embeds_one(:hooks, Schema.Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:verification, Schema.Verification, on_replace: :update, defaults_to_struct: true)
    field(:validation, {:array, :string}, default: [])
  end

  @type t :: %__MODULE__{}

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_repo_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config = normalize_keys(config)

    with :ok <- reject_unknown_keys(config) do
      config
      |> drop_nil_values()
      |> changeset()
      |> apply_action(:validate)
      |> case do
        {:ok, workflow} -> {:ok, workflow}
        {:error, changeset} -> {:error, {:invalid_repo_workflow_config, format_errors(changeset)}}
      end
    end
  end

  @spec to_config_map(t()) :: map()
  def to_config_map(%__MODULE__{} = workflow) do
    %{}
    |> maybe_put("hooks", hooks_to_map(workflow.hooks))
    |> maybe_put("verification", verification_to_map(workflow.verification))
    |> maybe_put("validation", workflow.validation)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:validation], empty_values: [])
    |> cast_embed(:hooks, with: &Schema.Hooks.changeset/2)
    |> cast_embed(:verification, with: &Schema.Verification.changeset/2)
    |> validate_string_list(:validation)
  end

  defp reject_unknown_keys(config) do
    unknown_keys = Map.keys(config) -- @allowed_keys

    case unknown_keys do
      [] ->
        :ok

      [key | _rest] ->
        {:error, {:invalid_repo_workflow_config, "WORKFLOW.md contains operator-level key `#{key}`; move operator-owned configuration to symphony.yml"}}
    end
  end

  defp validate_string_list(changeset, field) do
    validate_change(changeset, field, fn ^field, values ->
      invalid? = Enum.any?(values || [], &(not is_binary(&1) or String.trim(&1) == ""))

      if invalid?, do: [{field, "must contain only non-empty strings"}], else: []
    end)
  end

  defp hooks_to_map(nil), do: nil

  defp hooks_to_map(%Schema.Hooks{} = hooks) do
    %{
      "after_create" => hooks.after_create,
      "before_run" => hooks.before_run,
      "after_run" => hooks.after_run,
      "before_remove" => hooks.before_remove,
      "timeout_ms" => hooks.timeout_ms
    }
    |> drop_nil_values()
  end

  defp verification_to_map(nil), do: nil

  defp verification_to_map(%Schema.Verification{} = verification) do
    %{
      "enabled" => verification.enabled,
      "port_allocation" => %{
        "range" => verification.port_allocation.range
      },
      "dev_server" => %{
        "start_cmd" => verification.dev_server.start_cmd,
        "health_check_url" => verification.dev_server.health_check_url,
        "health_timeout_ms" => verification.dev_server.health_timeout_ms,
        "stop_signal" => verification.dev_server.stop_signal,
        "stop_timeout_ms" => verification.dev_server.stop_timeout_ms
      }
    }
    |> drop_nil_values()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        dropped -> Map.put(acc, key, dropped)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix = if is_nil(prefix), do: to_string(key), else: prefix <> "." <> to_string(key)
      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.flat_map(errors, fn
      error when is_binary(error) -> [prefix <> " " <> error]
      nested -> flatten_errors(nested, prefix)
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", inspect(value))
    end)
  end
end
