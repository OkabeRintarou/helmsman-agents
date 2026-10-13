defmodule Helmsman.GitHub.Repositories do
  @moduledoc """
  Repository availability and the GitHub calls made on one repository:
  push tokens, branch checks and branch lists (designs/15 §2).

  A repository is available when it is neither removed from its
  installation's scope nor archived, and its installation is neither
  disconnected nor suspended.
  """

  import Ecto.Query, warn: false

  alias Helmsman.GitHub.Client
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Repository
  alias Helmsman.GitHub.Tokens
  alias Helmsman.Repo

  @max_branches 1000

  @doc "Whether `repository` of `installation` is available."
  @spec available?(Repository.t(), Installation.t()) :: boolean()
  def available?(%Repository{} = repository, %Installation{} = installation) do
    is_nil(repository.removed_at) and not repository.archived and
      is_nil(installation.disconnected_at) and is_nil(installation.suspended_at)
  end

  @doc """
  Returns the repository with id `id` of workspace `workspace_id` with its
  installation, or nil.
  """
  @spec get(pos_integer(), integer()) :: {Repository.t(), Installation.t()} | nil
  def get(workspace_id, id) do
    Repo.one(
      from(r in Repository,
        join: i in Installation,
        on: i.id == r.installation_id,
        where: r.workspace_id == ^workspace_id and r.id == ^id,
        select: {r, i}
      )
    )
  end

  @doc """
  Returns the repository with its installation when it is available:
  `{:error, :not_found}` for unknown ids, `{:error, :repository_unavailable}`
  otherwise. Reads the current rows.
  """
  @spec fetch_available(pos_integer(), integer()) ::
          {:ok, {Repository.t(), Installation.t()}}
          | {:error, :not_found | :repository_unavailable}
  def fetch_available(workspace_id, id) do
    case get(workspace_id, id) do
      nil ->
        {:error, :not_found}

      {repository, installation} = pair ->
        if available?(repository, installation),
          do: {:ok, pair},
          else: {:error, :repository_unavailable}
    end
  end

  @doc """
  Signs a push token for `repository`: narrowed to it alone with
  `contents: write` (designs/15 §2). Unavailable repositories return
  `{:error, :repository_unavailable}` without calling GitHub.

  For server-side use only (the run description handed to the daemon);
  the token must never reach prompts, logs or run events.
  """
  @spec push_token(Repository.t()) ::
          {:ok, Tokens.token()} | {:error, :not_found | :repository_unavailable | Client.error()}
  def push_token(%Repository{workspace_id: workspace_id, id: id}) do
    with {:ok, {repository, installation}} <- fetch_available(workspace_id, id) do
      Tokens.get(installation.installation_id,
        repository_ids: [repository.github_id],
        permissions: %{"contents" => "write"}
      )
    end
  end

  @doc """
  Like `push_token/1`, but read-only (`contents: read`): a run-only
  autopilot run's checkout (`add-autopilots` decision 13).
  """
  @spec read_token(Repository.t()) ::
          {:ok, Tokens.token()} | {:error, :not_found | :repository_unavailable | Client.error()}
  def read_token(%Repository{workspace_id: workspace_id, id: id}) do
    with {:ok, {repository, installation}} <- fetch_available(workspace_id, id) do
      Tokens.get(installation.installation_id,
        repository_ids: [repository.github_id],
        permissions: %{"contents" => "read"}
      )
    end
  end

  @doc """
  Checks that `branch` exists in `repository` (an installation token
  narrowed to the repository).
  """
  @spec branch_exists?(Repository.t(), Installation.t(), String.t()) ::
          {:ok, boolean()} | {:error, Client.error()}
  def branch_exists?(%Repository{} = repository, %Installation{} = installation, branch)
      when is_binary(branch) do
    with {:ok, %{token: token}} <- repository_token(repository, installation) do
      path =
        "/repos/#{repository.owner}/#{repository.name}/branches/#{URI.encode(branch, &URI.char_unreserved?/1)}"

      case Client.request(:get, path, auth: {:token, token}) do
        {:ok, _branch} -> {:ok, true}
        {:error, :not_found} -> {:ok, false}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Lists the names of the first 1000 branches of `repository`."
  @spec list_branches(Repository.t(), Installation.t()) ::
          {:ok, [String.t()]} | {:error, Client.error()}
  def list_branches(%Repository{} = repository, %Installation{} = installation) do
    with {:ok, %{token: token}} <- repository_token(repository, installation),
         {:ok, branches} <-
           Client.paginate("/repos/#{repository.owner}/#{repository.name}/branches",
             auth: {:token, token},
             max: @max_branches
           ) do
      {:ok, for(%{"name" => name} <- branches, do: name)}
    end
  end

  defp repository_token(repository, installation),
    do: Tokens.get(installation.installation_id, repository_ids: [repository.github_id])
end
