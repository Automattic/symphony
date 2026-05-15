defmodule SymphonyElixir.SensitivePath do
  @moduledoc """
  Shared detection for obvious secret paths and filenames.
  """

  @sensitive_home_roots [
    "~/.ssh",
    "~/.aws",
    "~/.gnupg",
    "~/.docker",
    "~/.config/gh",
    "~/.claude/.credentials.json",
    "~/.claude/projects",
    "~/.claude/file-history",
    "~/.config/op",
    "~/.config/gcloud",
    "~/.azure",
    "~/.kube",
    "~/Library/Application Support",
    "~/.netrc",
    "~/.git-credentials",
    "~/.npmrc",
    "~/.cargo/credentials",
    "~/.bash_history",
    "~/.zsh_history",
    "~/.history",
    "~/.python_history",
    "~/.node_repl_history"
  ]

  @sensitive_path_segments [
    "/.ssh/",
    "/.aws/",
    "/.gnupg/",
    "/.docker/",
    "/.config/gh/",
    "/.config/op/",
    "/.config/gcloud/",
    "/.azure/",
    "/.kube/",
    "/Library/Application Support/",
    "/etc/sudoers/",
    "/etc/sudoers.d/",
    "/private/etc/sudoers/",
    "/private/etc/sudoers.d/",
    "/var/root/"
  ]

  @sensitive_path_basenames [
    ".netrc",
    ".git-credentials",
    ".npmrc",
    ".bash_history",
    ".zsh_history",
    ".history",
    ".python_history",
    ".node_repl_history"
  ]

  @sensitive_basename_prefixes [".env"]
  @sensitive_basename_suffixes [".pem", ".key"]

  @doc false
  @spec denied_secret_path([String.t()]) :: String.t() | nil
  def denied_secret_path(tokens) when is_list(tokens) do
    Enum.find_value(tokens, fn token ->
      token
      |> option_value()
      |> secret_path()
    end)
  end

  def denied_secret_path(_tokens), do: nil

  @doc false
  @spec secret_path(String.t()) :: String.t() | nil
  def secret_path(token) when is_binary(token) do
    normalized = token |> String.trim() |> String.trim_trailing(":")

    cond do
      sensitive_home_path?(normalized) ->
        normalized

      sensitive_absolute_path?(normalized) ->
        normalized

      sensitive_basename?(normalized) ->
        normalized

      true ->
        nil
    end
  end

  def secret_path(_token), do: nil

  defp sensitive_home_path?(path) do
    Enum.any?(@sensitive_home_roots, fn root ->
      path == root or String.starts_with?(path, root <> "/")
    end)
  end

  defp sensitive_absolute_path?(path) do
    path_with_slash = path <> "/"

    Enum.any?(@sensitive_path_segments, &String.contains?(path_with_slash, &1)) or
      sensitive_absolute_file?(path)
  end

  defp sensitive_absolute_file?("/" <> _rest = path) do
    basename = Path.basename(path)

    basename in @sensitive_path_basenames or String.ends_with?(path, "/.cargo/credentials")
  end

  defp sensitive_absolute_file?(_path), do: false

  @doc false
  @spec sensitive_basename?(Path.t()) :: boolean()
  def sensitive_basename?(path) when is_binary(path) do
    basename = path |> String.trim() |> String.trim_trailing(":") |> Path.basename()

    String.starts_with?(basename, @sensitive_basename_prefixes) or
      String.ends_with?(String.downcase(basename), @sensitive_basename_suffixes)
  end

  def sensitive_basename?(_path), do: false

  defp option_value(token) when is_binary(token) do
    case String.split(token, "=", parts: 2) do
      [_option, value] -> value
      [value] -> value
    end
  end

  defp option_value(token), do: token
end
