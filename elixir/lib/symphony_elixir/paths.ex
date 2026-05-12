defmodule SymphonyElixir.Paths do
  @moduledoc """
  Resolves filesystem paths used for Symphony runtime state.
  """

  @app :symphony_elixir
  @state_root_env "SYMPHONY_STATE_ROOT"
  @logs_root_env "SYMPHONY_LOGS_ROOT"
  @state_root_override_key :state_root_override
  @logs_root_override_key :logs_root_override

  @spec state_root() :: Path.t()
  def state_root do
    configured_root(@state_root_override_key) ||
      env_root(@state_root_env) ||
      configured_root(:state_root) ||
      default_state_root()
  end

  @spec logs_root() :: Path.t()
  def logs_root do
    configured_root(@logs_root_override_key) ||
      env_root(@logs_root_env) ||
      configured_root(:logs_root) ||
      default_logs_root()
  end

  @spec log_file() :: Path.t()
  def log_file do
    Path.join(logs_root(), "symphony.log")
  end

  @spec run_store_dir() :: Path.t()
  def run_store_dir do
    Path.join(state_root(), "run_store")
  end

  @spec audit_dir() :: Path.t()
  def audit_dir do
    Path.join(state_root(), "audit")
  end

  @spec secret_key_base_file() :: Path.t()
  def secret_key_base_file do
    Path.join(state_root(), "secret_key_base")
  end

  @spec set_state_root(Path.t()) :: :ok
  def set_state_root(root) when is_binary(root) do
    Application.put_env(@app, @state_root_override_key, Path.expand(root))
    :ok
  end

  @spec set_logs_root(Path.t()) :: :ok
  def set_logs_root(root) when is_binary(root) do
    expanded_root = Path.expand(root)
    Application.put_env(@app, @logs_root_override_key, expanded_root)
    Application.put_env(@app, :log_file, Path.join(expanded_root, "symphony.log"))
    :ok
  end

  @spec set_state_root_from_env() :: :ok
  def set_state_root_from_env do
    set_root_from_env(@state_root_env, :state_root)
  end

  @spec set_logs_root_from_env() :: :ok
  def set_logs_root_from_env do
    set_root_from_env(@logs_root_env, :logs_root)
  end

  defp set_root_from_env(env_name, app_env_key) do
    case env_root(env_name) do
      nil -> :ok
      root -> Application.put_env(@app, app_env_key, root)
    end

    :ok
  end

  defp configured_root(key) do
    @app
    |> Application.get_env(key)
    |> normalize_root()
  end

  defp env_root(name) do
    name
    |> System.get_env()
    |> normalize_root()
  end

  defp normalize_root(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      root -> Path.expand(root)
    end
  end

  defp normalize_root(_value), do: nil

  defp default_state_root do
    Path.join([System.user_home!(), "Library", "Application Support", "symphony"])
  end

  defp default_logs_root do
    Path.join([System.user_home!(), "Library", "Logs", "symphony"])
  end
end
