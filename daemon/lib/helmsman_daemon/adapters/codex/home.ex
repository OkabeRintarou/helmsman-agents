defmodule HelmsmanDaemon.Adapters.Codex.Home do
  @moduledoc false
  alias HelmsmanDaemon.{Config, Env, Paths}

  def configured(nil, _env), do: {:ok, nil}

  def configured(path, env) when is_binary(path) and path != "" do
    cond do
      Path.type(path) == :absolute ->
        {:ok, Path.expand(path)}

      String.starts_with?(path, "~/") and nonempty?(env["HOME"]) ->
        {:ok, Path.expand(String.trim_leading(path, "~/"), env["HOME"])}

      true ->
        {:error, :invalid_codex_home}
    end
  end

  def configured(_, _env), do: {:error, :invalid_codex_home}

  def resolve(env \\ Env.child()) do
    case Process.whereis(Config) do
      nil ->
        with {:ok, config} <- Config.load(), do: location(config.codex_home, env)

      _pid ->
        Config.get().codex_location
    end
  end

  def location(private_home, env) do
    cond do
      private_home -> {:ok, {:private, private_home}}
      nonempty?(env["CODEX_HOME"]) -> {:ok, {:user, Path.expand(env["CODEX_HOME"])}}
      nonempty?(env["HOME"]) -> {:ok, {:user, Path.join(env["HOME"], ".codex")}}
      true -> {:error, "cannot locate the Codex home: HOME is not set"}
    end
  end

  def prepare({:user, path}), do: path

  def prepare({:private, path}) do
    # An explicit private Codex home may be outside HELMSMAN_HOME. Only create
    # and chmod that directory; never change permissions of its parents.
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  def migration_hint({:user, path}) do
    old = Path.join(Paths.home(), "codex")

    if path != old and match?({:ok, [_ | _]}, File.ls(old)) do
      "Codex now uses #{path} (your own Codex configuration). #{old} is no longer used; to keep using it, set [codex] home = #{JSON.encode!(old)} in #{Path.join(Paths.home(), "config.toml")}. Existing task sessions from the old directory may fail to resume once; retry to start a new session."
    end
  end

  def migration_hint(_), do: nil
  defp nonempty?(value), do: is_binary(value) and value != ""
end
