defmodule Helmsman.GitHub.AppConfig do
  @moduledoc """
  The instance's GitHub App configuration (designs/15 §1).

  The five environment variables `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`,
  `GITHUB_WEBHOOK_SECRET`, `GITHUB_APP_CLIENT_ID` and
  `GITHUB_APP_CLIENT_SECRET`, when all set, take precedence over the
  `github_apps` row created by the manifest flow. A found configuration is
  cached in `:persistent_term` (unless `config :helmsman,
  Helmsman.GitHub.AppConfig, cache: false`) and dropped by `invalidate/0`;
  "not configured" is never cached.

  `inspect` never shows the private key nor the two secrets.
  """

  alias Helmsman.GitHub.App
  alias Helmsman.Repo

  @derive {Inspect, except: [:private_key, :webhook_secret, :client_secret]}
  defstruct [
    :source,
    :app_id,
    :slug,
    :name,
    :html_url,
    :owner_login,
    :client_id,
    :client_secret,
    :private_key,
    :webhook_secret
  ]

  @type t :: %__MODULE__{
          source: :env | :database,
          app_id: pos_integer(),
          slug: String.t() | nil,
          name: String.t() | nil,
          html_url: String.t() | nil,
          owner_login: String.t() | nil,
          client_id: String.t(),
          client_secret: String.t(),
          private_key: String.t(),
          webhook_secret: String.t()
        }

  @env_vars ~w(GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY GITHUB_WEBHOOK_SECRET
               GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET)

  @cache_key {__MODULE__, :current}

  @doc "Returns the App configuration, or `{:error, :github_not_configured}`."
  @spec current() :: {:ok, t()} | {:error, :github_not_configured}
  def current do
    if cache?() do
      case :persistent_term.get(@cache_key, nil) do
        nil -> load_and_cache()
        config -> {:ok, config}
      end
    else
      load()
    end
  end

  # Only a configuration is cached, never its absence: the one change at
  # runtime is "none" → the manifest's App, and a read that found none
  # could otherwise store its result after the App's invalidation.
  defp load_and_cache do
    with {:ok, config} <- load() do
      :persistent_term.put(@cache_key, config)
      {:ok, config}
    end
  end

  @doc "Drops the cached configuration (after the manifest flow saved one)."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc "Whether all five environment variables are set."
  @spec env_configured?() :: boolean()
  def env_configured?, do: match?({:ok, _}, from_env())

  defp cache?, do: Keyword.get(Application.get_env(:helmsman, __MODULE__, []), :cache, true)

  defp load do
    with :error <- from_env(),
         :error <- from_database() do
      {:error, :github_not_configured}
    end
  end

  defp from_env do
    values = Enum.map(@env_vars, &System.get_env/1)

    with true <- Enum.all?(values, &present?/1),
         [app_id, key, webhook_secret, client_id, client_secret] = values,
         {id, ""} when id > 0 <- Integer.parse(String.trim(app_id)) do
      {:ok,
       %__MODULE__{
         source: :env,
         app_id: id,
         private_key: normalize_pem(key),
         webhook_secret: webhook_secret,
         client_id: client_id,
         client_secret: client_secret
       }}
    else
      _ -> :error
    end
  end

  # Keys passed through single-line variables often carry literal "\n".
  defp normalize_pem(key), do: String.replace(key, "\\n", "\n")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp from_database do
    case Repo.one(App) do
      nil ->
        :error

      %App{} = app ->
        {:ok,
         %__MODULE__{
           source: :database,
           app_id: app.app_id,
           slug: app.slug,
           name: app.name,
           html_url: app.html_url,
           owner_login: app.owner_login,
           client_id: app.client_id,
           client_secret: app.client_secret,
           private_key: app.private_key,
           webhook_secret: app.webhook_secret
         }}
    end
  end
end
