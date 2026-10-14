defmodule HelmsmanWeb.InstallScript do
  @moduledoc """
  The `/install.sh` script (`add-release-distribution` decision 11),
  rendered from `priv/install.sh.eex` with the instance's public URL and
  version. It never contains a token.
  """

  require EEx

  @template Path.expand("../../priv/install.sh.eex", __DIR__)
  @external_resource @template

  EEx.function_from_file(:defp, :template, @template, [:assigns])

  @doc """
  Renders the script for the server at `public_url` (default: the
  instance's) and `version` (default: the server's).
  """
  @spec render(String.t(), String.t()) :: String.t()
  def render(public_url \\ public_url(), version \\ version()) do
    template(%{
      server: quote_sh(public_url),
      version: quote_sh(version),
      server_comment: one_line(public_url),
      version_comment: one_line(version)
    })
  end

  @doc "The server's version, as the script and `/readyz` report it."
  @spec version() :: String.t()
  def version, do: :helmsman |> Application.spec(:vsn) |> to_string()

  defp public_url do
    :helmsman
    |> Application.get_env(:public_url, "http://localhost:4000")
    |> String.trim_trailing("/")
  end

  defp quote_sh(value), do: "'" <> String.replace(one_line(value), "'", ~S('\'')) <> "'"

  defp one_line(value), do: String.replace(value, ~r/[\x00-\x1f\x7f]/, "")
end
