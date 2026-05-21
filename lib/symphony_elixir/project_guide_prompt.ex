defmodule SymphonyElixir.ProjectGuidePrompt do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ProjectGuides

  @type runner :: ProjectGuides.runner()

  @spec append_to_prompt(String.t(), Path.t(), Schema.t(), runner()) :: {:ok, String.t()} | {:error, term()}
  def append_to_prompt(prompt, workspace, %Schema{} = settings, runner) when is_binary(prompt) do
    append_to_prompt(prompt, workspace, settings, runner, ProjectGuides)
  end

  @doc false
  @spec append_to_prompt(String.t(), Path.t(), Schema.t(), runner(), module()) :: {:ok, String.t()} | {:error, term()}
  def append_to_prompt(prompt, workspace, %Schema{} = settings, runner, module) when is_binary(prompt) and is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        log_project_guides_unavailable(runner, :module_unavailable)
        {:ok, prompt}

      not function_exported?(module, :append_to_prompt, 4) ->
        log_project_guides_unavailable(runner, :function_unavailable)
        {:ok, prompt}

      true ->
        apply_project_guides(module, prompt, workspace, settings, runner)
    end
  end

  defp apply_project_guides(module, prompt, workspace, settings, runner) do
    module.append_to_prompt(prompt, workspace, settings, runner)
  rescue
    error in UndefinedFunctionError ->
      case missing_append_to_prompt?(error, module) do
        true ->
          log_project_guides_unavailable(runner, :undefined_function)
          {:ok, prompt}

        false ->
          {:error, {:project_guides_failed, compact_exception(error)}}
      end

    error ->
      {:error, {:project_guides_failed, compact_exception(error)}}
  catch
    kind, reason ->
      {:error, {:project_guides_failed, kind, compact_term(reason)}}
  end

  defp missing_append_to_prompt?(%UndefinedFunctionError{} = error, module) do
    Map.get(error, :module) == module and Map.get(error, :function) == :append_to_prompt and Map.get(error, :arity) == 4
  end

  defp log_project_guides_unavailable(runner, reason) do
    Logger.warning("Project guide injection unavailable runner=#{runner} reason=#{reason}; continuing without project guides")
  end

  defp compact_exception(%UndefinedFunctionError{} = error) do
    {:undefined_function, Map.get(error, :module), Map.get(error, :function), Map.get(error, :arity)}
  end

  defp compact_exception(%{__struct__: module}), do: module

  defp compact_term(reason) when is_atom(reason) or is_number(reason) or is_boolean(reason) or is_nil(reason), do: reason

  defp compact_term(reason) when is_binary(reason) do
    if byte_size(reason) <= 256 do
      reason
    else
      binary_part(reason, 0, 256) <> "... (truncated)"
    end
  end

  defp compact_term(%{__struct__: module}), do: module

  defp compact_term(reason), do: inspect(reason, limit: 5, printable_limit: 256)
end
