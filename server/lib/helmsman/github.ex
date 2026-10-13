defmodule Helmsman.GitHub do
  @moduledoc """
  GitHub integration (designs/15): the instance's GitHub App, installations
  linked to workspaces, synced repositories, webhooks and tokens.

  The only entry point for other contexts and the web layer; everything
  under `Helmsman.GitHub.*` except the schemas is internal. GitHub requests
  never run inside a database transaction. Committed changes to a
  workspace's installation or repositories broadcast `{:github_changed}` on
  the workspace topic; subscribers read `status/1` again.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.GitHub.App
  alias Helmsman.GitHub.AppConfig
  alias Helmsman.GitHub.Client
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Repositories
  alias Helmsman.GitHub.Repository
  alias Helmsman.GitHub.Webhooks
  alias Helmsman.GitHub.Workers.SyncRepositories
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Workspaces.Workspace

  import Ecto.Query, warn: false

  @login_format ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/
  @max_app_name 34

  @permissions %{
    contents: "write",
    pull_requests: "write",
    checks: "read",
    statuses: "read",
    metadata: "read"
  }
  @events ~w(pull_request check_suite check_run status repository)

  ## App (instance administrators)

  @doc """
  Builds the GitHub App manifest form (`:manage_github_app`, design decision
  5) from `params`:

    * `:name` - the App name (at most 34 characters)
    * `:owner_org` - an organization login, or nil/"" for the personal account
    * `:public?` - whether other accounts may install the App
    * `:base_url` - this server's public URL, e.g. `"https://helmsman.example"`

  Returns `%{action_url: url, manifest_json: json}`; the web layer adds the
  signed `state` to `action_url`. Refused when an App is already configured.
  """
  @spec manifest(Scope.t(), map()) ::
          {:ok, %{action_url: String.t(), manifest_json: String.t()}}
          | {:error, :forbidden | :already_configured | :invalid_params}
  def manifest(%Scope{} = scope, params) do
    with :ok <- Policy.authorize(scope, :manage_github_app),
         :ok <- ensure_not_configured(),
         {:ok, name, org, public?, base_url} <- manifest_params(params) do
      base_url = String.trim_trailing(base_url, "/")

      manifest = %{
        name: name,
        url: base_url,
        hook_attributes: %{url: base_url <> "/webhooks/github", active: true},
        redirect_url: base_url <> "/admin/github/callback",
        callback_urls: [base_url <> "/github/setup"],
        setup_url: base_url <> "/github/setup",
        setup_on_update: true,
        request_oauth_on_install: true,
        public: public?,
        default_permissions: @permissions,
        default_events: @events
      }

      action_url =
        case org do
          nil -> Client.web_url() <> "/settings/apps/new"
          org -> Client.web_url() <> "/organizations/#{org}/settings/apps/new"
        end

      {:ok, %{action_url: action_url, manifest_json: Jason.encode!(manifest)}}
    end
  end

  defp manifest_params(params) do
    name = params |> param(:name) |> to_string() |> String.trim()
    org = params |> param(:owner_org) |> blank_to_nil()
    base_url = param(params, :base_url)

    cond do
      name == "" or String.length(name) > @max_app_name -> {:error, :invalid_params}
      org != nil and not Regex.match?(@login_format, org) -> {:error, :invalid_params}
      not valid_base_url?(base_url) -> {:error, :invalid_params}
      true -> {:ok, name, org, param(params, :public?) in [true, "true"], base_url}
    end
  end

  defp valid_base_url?(url) when is_binary(url) do
    match?(
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and host != nil,
      URI.parse(url)
    )
  end

  defp valid_base_url?(_url), do: false

  defp param(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      value -> value
    end
  end

  defp ensure_not_configured do
    if AppConfig.env_configured?() or Repo.exists?(App),
      do: {:error, :already_configured},
      else: :ok
  end

  @doc """
  Completes the manifest flow (`:manage_github_app`): exchanges the
  one-time `code` for the App's credentials and saves them. The caller has
  verified the flow's `state`. Refused when an App is already configured.
  """
  @spec complete_manifest(Scope.t(), String.t()) ::
          {:ok, map()} | {:error, :forbidden | :already_configured | Client.error()}
  def complete_manifest(%Scope{} = scope, code) when is_binary(code) do
    with :ok <- Policy.authorize(scope, :manage_github_app),
         :ok <- ensure_not_configured(),
         {:ok, body} <-
           Client.request(
             :post,
             "/app-manifests/#{URI.encode(code, &URI.char_unreserved?/1)}/conversions"
           ),
         {:ok, _app} <- insert_app(body, scope.user.id) do
      AppConfig.invalidate()
      app_overview(scope)
    end
  end

  defp insert_app(body, user_id) do
    attrs = %{
      app_id: body["id"],
      slug: body["slug"],
      name: body["name"],
      html_url: body["html_url"],
      owner_login: get_in(body, ["owner", "login"]),
      client_id: body["client_id"],
      client_secret: body["client_secret"],
      private_key: body["pem"],
      webhook_secret: body["webhook_secret"]
    }

    %App{created_by_id: user_id}
    |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
    |> Ecto.Changeset.validate_required(Map.keys(attrs) -- [:owner_login])
    |> Ecto.Changeset.unique_constraint(:app_id, name: :github_apps_single_row)
    |> Repo.insert()
    |> case do
      {:ok, app} ->
        {:ok, app}

      {:error, %Ecto.Changeset{errors: errors}} ->
        case errors[:app_id] do
          {_message, [{:constraint, :unique} | _]} -> {:error, :already_configured}
          _ -> {:error, {:github_unavailable, :unexpected_response}}
        end
    end
  end

  @doc """
  The App configuration overview for instance administrators
  (`:manage_github_app`): source, App ID, name, slug, home page and owner.
  Never includes a secret.
  """
  @spec app_overview(Scope.t()) :: {:ok, map()} | {:error, :forbidden}
  def app_overview(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :manage_github_app) do
      case AppConfig.current() do
        {:ok, config} ->
          {:ok,
           %{
             configured?: true,
             source: config.source,
             app_id: config.app_id,
             name: config.name,
             slug: config.slug,
             html_url: config.html_url,
             owner_login: config.owner_login
           }}

        {:error, :github_not_configured} ->
          {:ok, %{configured?: false}}
      end
    end
  end

  @doc """
  The App's installation page carrying `state`. An App configured by
  environment variables has no stored slug; it is read from `GET /app`.
  """
  @spec install_url(String.t()) :: {:ok, String.t()} | {:error, Client.error()}
  def install_url(state) when is_binary(state) do
    with {:ok, config} <- AppConfig.current(),
         {:ok, slug} <- app_slug(config) do
      query = URI.encode_query(%{state: state})
      {:ok, "#{Client.web_url()}/apps/#{slug}/installations/new?#{query}"}
    end
  end

  defp app_slug(%AppConfig{slug: slug}) when is_binary(slug), do: {:ok, slug}

  defp app_slug(%AppConfig{}) do
    case Client.request(:get, "/app", auth: :app) do
      {:ok, %{"slug" => slug}} when is_binary(slug) -> {:ok, slug}
      {:ok, _body} -> {:error, {:github_unavailable, :unexpected_response}}
      {:error, _reason} = error -> error
    end
  end

  ## Installations (workspace owners and admins)

  @doc "See `Helmsman.GitHub.Installations.connect/3`."
  @spec connect_installation(Scope.t(), integer(), String.t() | nil) ::
          {:ok, Helmsman.GitHub.Installation.t()} | {:error, Installations.connect_error()}
  defdelegate connect_installation(scope, installation_id, code),
    to: Installations,
    as: :connect

  @doc "See `Helmsman.GitHub.Installations.disconnect/1`."
  @spec disconnect_installation(Scope.t()) ::
          {:ok, Helmsman.GitHub.Installation.t()} | {:error, :forbidden | :not_found}
  defdelegate disconnect_installation(scope), to: Installations, as: :disconnect

  ## Webhooks

  @doc "See `Helmsman.GitHub.Webhooks.receive/2`."
  @spec receive_webhook(binary(), map()) :: Webhooks.result()
  defdelegate receive_webhook(raw_body, headers), to: Webhooks, as: :receive

  ## Reading

  @doc """
  The workspace's GitHub status (`:view_workspace`): whether the App is
  configured, the installation (the connected one, else the last
  disconnected one) and its repositories with their availability.
  """
  @spec status(Scope.t()) :: {:ok, map()} | {:error, :forbidden}
  def status(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :view_workspace) do
      app =
        case AppConfig.current() do
          {:ok, config} -> %{name: config.name, slug: config.slug, html_url: config.html_url}
          {:error, _} -> nil
        end

      installation = Installations.for_workspace(workspace_id)

      {:ok,
       %{
         configured?: app != nil,
         app: app,
         installation: installation && installation_status(installation),
         repositories: repositories_status(workspace_id)
       }}
    end
  end

  defp installation_status(installation) do
    %{
      account_login: installation.account_login,
      account_type: installation.account_type,
      suspended?: installation.suspended_at != nil,
      disconnected?: installation.disconnected_at != nil,
      settings_url: settings_url(installation)
    }
  end

  # Where the account manages the installation's repository access on
  # GitHub (`add-github-ui` R4).
  defp settings_url(%{account_type: "Organization"} = installation),
    do:
      "#{Client.web_url()}/organizations/#{installation.account_login}/settings/installations/" <>
        "#{installation.installation_id}"

  defp settings_url(installation),
    do: "#{Client.web_url()}/settings/installations/#{installation.installation_id}"

  defp repositories_status(workspace_id) do
    from(r in Repository,
      join: i in assoc(r, :installation),
      where: r.workspace_id == ^workspace_id and is_nil(r.removed_at),
      order_by: [asc: r.owner, asc: r.name],
      select: {r, i}
    )
    |> Repo.all()
    |> Enum.map(fn {repository, installation} ->
      %{
        id: repository.id,
        full_name: Repository.full_name(repository),
        default_branch: repository.default_branch,
        private: repository.private,
        archived: repository.archived,
        available: Repositories.available?(repository, installation)
      }
    end)
  end

  @doc """
  Queues a repository sync of the workspace's connected installation
  (`:manage_github`; `add-github-ui` R6), the job of the daily sync (one
  queued per installation at a time). `{:error, :not_found}` without a
  connected installation.
  """
  @spec request_sync(Scope.t()) :: :ok | {:error, :forbidden | :not_found}
  def request_sync(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :manage_github) do
      case Installations.for_workspace(workspace_id) do
        %Installation{disconnected_at: nil, installation_id: id} ->
          {:ok, _job} = Oban.insert(SyncRepositories.new(%{installation_id: id}))
          :ok

        _ ->
          {:error, :not_found}
      end
    end
  end

  @doc "Lists the first 1000 branch names of an available repository (`:manage_github`)."
  @spec list_branches(Scope.t(), integer()) ::
          {:ok, [String.t()]}
          | {:error, :forbidden | :not_found | :repository_unavailable | Client.error()}
  def list_branches(%Scope{workspace: %Workspace{id: workspace_id}} = scope, repository_id)
      when is_integer(repository_id) do
    with :ok <- Policy.authorize(scope, :manage_github),
         {:ok, {repository, installation}} <-
           Repositories.fetch_available(workspace_id, repository_id) do
      Repositories.list_branches(repository, installation)
    end
  end

  ## Tokens and checks for other contexts

  @doc "See `Helmsman.GitHub.Repositories.push_token/1`."
  @spec push_token(Repository.t()) :: {:ok, map()} | {:error, term()}
  defdelegate push_token(repository), to: Repositories

  @doc """
  Checks that `branch` exists in the repository: `{:ok, true | false}`.
  Unavailable repositories return `{:error, :repository_unavailable}`.
  """
  @spec branch_exists?(Repository.t(), String.t()) ::
          {:ok, boolean()} | {:error, :not_found | :repository_unavailable | Client.error()}
  def branch_exists?(%Repository{workspace_id: workspace_id, id: id}, branch) do
    with {:ok, {repository, installation}} <- Repositories.fetch_available(workspace_id, id) do
      Repositories.branch_exists?(repository, installation, branch)
    end
  end
end
