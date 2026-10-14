defmodule HelmsmanDaemon.Release do
  @moduledoc """
  Version, target and launch mode of the running daemon.

  The installed binary is a Burrito wrapper around a release; `mix helmsman …`
  runs the same CLI from the source tree. Burrito is a `:prod`-only dependency,
  so its functions are looked up at runtime.
  """

  @doc "Daemon version (repository `VERSION`)."
  def version, do: :helmsman_daemon |> Application.spec(:vsn) |> to_string()

  @doc "True when running as the installed single-file binary."
  def standalone? do
    case burrito(Util) do
      nil -> false
      module -> module.running_standalone?()
    end
  end

  @doc "Command-line arguments of the binary, or of `mix helmsman` (handled by the mix task)."
  def argv do
    case burrito(Util.Args) do
      nil -> System.argv()
      module -> module.argv()
    end
  end

  @doc "Absolute path of the installed binary; nil when not standalone."
  def executable do
    with true <- standalone?(),
         module when module != nil <- burrito(Util.Args),
         path when is_binary(path) <- module.get_bin_path() do
      Path.expand(path)
    else
      _ -> nil
    end
  end

  @doc "Release target such as `linux-x64`, derived from the running OS; `dev` under mix."
  def target(standalone? \\ standalone?()) do
    if standalone?, do: platform_target(), else: "dev"
  end

  def platform_target(os \\ :os.type(), arch \\ :erlang.system_info(:system_architecture)) do
    os =
      case os do
        {:unix, :darwin} -> "macos"
        {_, name} -> Atom.to_string(name)
      end

    cpu =
      case arch |> to_string() |> String.split("-") |> hd() do
        "x86_64" -> "x64"
        cpu when cpu in ["aarch64", "arm64"] -> "arm64"
        cpu -> cpu
      end

    "#{os}-#{cpu}"
  end

  def version_line(standalone? \\ standalone?()) do
    "helmsman #{version()} (protocol #{HelmsmanProtocol.version()}, #{target(standalone?)})"
  end

  defp burrito(name) do
    module = Module.concat(Burrito, name)
    if Code.ensure_loaded?(module), do: module
  end
end
