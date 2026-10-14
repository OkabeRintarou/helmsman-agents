defmodule HelmsmanDaemon.Platform do
  @moduledoc "Operating system family of this machine."

  @type t :: :linux | :macos | :other

  @spec os() :: t()
  def os do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :macos
      _ -> :other
    end
  end
end
