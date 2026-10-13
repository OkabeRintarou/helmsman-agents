defmodule Helmsman.Config do
  @moduledoc """
  Instance settings the domain needs without depending on the web layer.
  """

  @doc """
  The instance's public base URL without a trailing slash
  (`config :helmsman, :public_url`; production derives it from PHX_HOST).
  """
  @spec public_url() :: String.t()
  def public_url do
    :helmsman
    |> Application.get_env(:public_url, "http://localhost:4000")
    |> String.trim_trailing("/")
  end

  @doc "How many times a pull request is reopened automatically (default 3)."
  @spec max_auto_reopens() :: non_neg_integer()
  def max_auto_reopens do
    :helmsman
    |> Application.get_env(Helmsman.GitHub, [])
    |> Keyword.get(:max_auto_reopens, 3)
  end
end
