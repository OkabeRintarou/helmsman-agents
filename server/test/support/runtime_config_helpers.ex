defmodule Helmsman.RuntimeConfigHelpers do
  @moduledoc """
  Evaluates `config/runtime.exs` as production would, with the given
  environment variables (use only in `async: false` modules: it changes
  the process environment and restores it).
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  # The variables runtime.exs reads in production; all are unset first.
  @vars ~w(DATABASE_URL SECRET_KEY_BASE HELMSMAN_VAULT_KEY PHX_HOST PHX_URL_SCHEME
           PHX_URL_PORT PHX_SERVER PORT HELMSMAN_SIGNUP HELMSMAN_MAILER_ADAPTER
           HELMSMAN_MAILER_FROM HELMSMAN_TRUSTED_PROXIES HELMSMAN_DATA_DIR
           HELMSMAN_DAEMON_DIST_DIR HELMSMAN_DAEMON_DOWNLOAD_URL HELMSMAN_LOG_FORMAT
           HELMSMAN_LOG_LEVEL POOL_SIZE ECTO_IPV6 DNS_CLUSTER_QUERY RELEASE_NAME)

  @doc "A complete production environment, merged with `overrides`."
  def prod_env(overrides \\ %{}) do
    Map.merge(
      %{
        "DATABASE_URL" => "ecto://u:p@localhost/db",
        "SECRET_KEY_BASE" => String.duplicate("a", 64),
        "HELMSMAN_VAULT_KEY" => Base.encode64(<<0::256>>),
        "PHX_HOST" => "hm.example.com",
        "HELMSMAN_MAILER_ADAPTER" => "log"
      },
      overrides
    )
  end

  @doc """
  Evaluates runtime.exs for `:prod` with exactly `env` set (a map; a `nil`
  value leaves the variable unset) and returns the configuration.
  """
  def read_prod_runtime(env) do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    try do
      Enum.each(@vars, &System.delete_env/1)
      Enum.each(env, fn {name, value} -> if value, do: System.put_env(name, value) end)
      Config.Reader.read!(@runtime, env: :prod, target: :host)
    after
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
