defmodule Helmsman.GitHub.PullRequests.Api do
  @moduledoc """
  The GitHub calls of the pull request reconciliation
  (`add-pr-reconcile-merge` decisions 5–7). Every call names the
  repository of the row it is about (decision 20) and authenticates with
  an installation token narrowed to that repository. HTTP only: callers
  never hold a transaction open around these calls.
  """

  alias Helmsman.GitHub.{Client, Installation, Repository, Tokens}

  @type repo :: %{repository: Repository.t(), installation: Installation.t()}
  @type facts :: %{
          number: pos_integer(),
          node_id: String.t(),
          url: String.t(),
          state: :draft | :open | :merged | :closed,
          head_sha: String.t() | nil,
          head_ref: String.t() | nil,
          base_branch: String.t() | nil,
          merge_commit_sha: String.t() | nil,
          mergeable: boolean() | nil,
          mergeable_state: String.t() | nil
        }

  @max_check_pages 3

  @doc "Normalizes a pull request object of the REST API."
  @spec facts(map()) :: facts()
  def facts(%{} = pr) do
    %{
      number: pr["number"],
      node_id: pr["node_id"],
      url: pr["html_url"],
      state: state(pr),
      head_sha: get_in(pr, ["head", "sha"]),
      head_ref: get_in(pr, ["head", "ref"]),
      base_branch: get_in(pr, ["base", "ref"]),
      merge_commit_sha: pr["merge_commit_sha"],
      mergeable: pr["mergeable"],
      mergeable_state: pr["mergeable_state"]
    }
  end

  defp state(%{"merged" => true}), do: :merged
  defp state(%{"merged_at" => at}) when is_binary(at), do: :merged
  defp state(%{"state" => "closed"}), do: :closed
  defp state(%{"draft" => true}), do: :draft
  defp state(_pr), do: :open

  @doc "Reads pull request `number`."
  @spec get(repo(), pos_integer()) :: {:ok, facts()} | {:error, Client.error()}
  def get(repo, number) do
    with {:ok, pr} <- call(repo, :get, "/pulls/#{number}"), do: {:ok, facts(pr)}
  end

  @doc "The open pull requests from `branch` into `base` (decision 5 step 2)."
  @spec find_open(repo(), String.t(), String.t()) :: {:ok, [facts()]} | {:error, Client.error()}
  def find_open(repo, branch, base) do
    params = [head: "#{repo.repository.owner}:#{branch}", base: base, state: "open"]

    with {:ok, prs} <- call(repo, :get, "/pulls", params: params, per_page: 100) do
      {:ok, Enum.map(prs, &facts/1)}
    end
  end

  @doc """
  Opens a pull request. 422 errors are told apart by GitHub's message:
  `:draft_unsupported`, `:already_exists`, `:head_invalid`.
  """
  @spec create(repo(), map()) ::
          {:ok, facts()}
          | {:error, :draft_unsupported | :already_exists | :head_invalid | Client.error()}
  def create(repo, params) do
    body = %{
      title: params.title,
      head: params.head,
      base: params.base,
      body: params.body,
      draft: params.draft
    }

    case call(repo, :post, "/pulls", json: body, error_body: true) do
      {:ok, pr} -> {:ok, facts(pr)}
      {:error, {:github_error, 422, error}} -> {:error, create_error(error)}
      {:error, {:github_error, status, _body}} -> {:error, {:github_error, status}}
      error -> error
    end
  end

  defp create_error(error) do
    text = error_text(error)

    cond do
      text =~ "Draft pull requests are not supported" -> :draft_unsupported
      text =~ "A pull request already exists" -> :already_exists
      text =~ ~r/head|invalid|not found/i -> :head_invalid
      true -> {:github_error, 422}
    end
  end

  # GitHub's message and the messages of its `errors` entries.
  defp error_text(%{} = error) do
    messages = for %{} = e <- List.wrap(error["errors"]), do: e["message"] || e["field"] || ""
    Enum.join([error["message"] || "" | messages], " ")
  end

  defp error_text(_error), do: ""

  @doc "Creates `refs/heads/<branch>` at `sha` (restoring a deleted task branch)."
  @spec create_ref(repo(), String.t(), String.t()) :: :ok | {:error, Client.error()}
  def create_ref(repo, branch, sha) do
    case call(repo, :post, "/git/refs", json: %{ref: "refs/heads/" <> branch, sha: sha}) do
      {:ok, _ref} -> :ok
      error -> error
    end
  end

  @doc "Sets the state of pull request `number`: `closed` or `open`."
  @spec set_state(repo(), pos_integer(), String.t()) :: {:ok, facts()} | {:error, Client.error()}
  def set_state(repo, number, state) do
    with {:ok, pr} <- call(repo, :patch, "/pulls/#{number}", json: %{state: state}),
         do: {:ok, facts(pr)}
  end

  @doc "Converts a pull request to a draft or marks it ready for review (GraphQL)."
  @spec set_draft(repo(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_draft(repo, node_id, draft?) do
    mutation =
      if draft?,
        do: "convertPullRequestToDraft",
        else: "markPullRequestReadyForReview"

    query =
      "mutation($id: ID!) { #{mutation}(input: {pullRequestId: $id}) " <>
        "{ pullRequest { isDraft } } }"

    with {:ok, token} <- token(repo) do
      case Client.request(:post, "/graphql",
             auth: {:token, token},
             json: %{query: query, variables: %{id: node_id}}
           ) do
        {:ok, %{"errors" => [_ | _] = errors}} -> {:error, {:graphql, graphql_messages(errors)}}
        {:ok, _data} -> :ok
        error -> error
      end
    end
  end

  defp graphql_messages(errors), do: Enum.map_join(errors, "; ", &(&1["message"] || ""))

  @doc """
  Merges pull request `number` at `sha` with `method`: `{:ok, merge_sha}`,
  `{:error, :head_changed}` (409, or 422 for a moved head) or
  `{:error, {:not_allowed, message}}` (405).
  """
  @spec merge(repo(), pos_integer(), String.t(), String.t()) ::
          {:ok, String.t() | nil}
          | {:error, :head_changed | {:not_allowed, String.t()} | Client.error()}
  def merge(repo, number, sha, method) do
    case call(repo, :put, "/pulls/#{number}/merge",
           json: %{sha: sha, merge_method: method},
           error_body: true
         ) do
      {:ok, body} ->
        {:ok, body["sha"]}

      {:error, {:github_error, status, _body}} when status in [409, 422] ->
        {:error, :head_changed}

      {:error, {:github_error, 405, body}} ->
        {:error, {:not_allowed, error_text(body)}}

      {:error, {:github_error, status, _body}} ->
        {:error, {:github_error, status}}

      error ->
        error
    end
  end

  @doc """
  The check runs (at most #{@max_check_pages} pages) and the latest commit
  statuses of `sha`: `%{runs: [...], statuses: [...]}`. Runs beyond those
  pages are not read.
  """
  @spec checks(repo(), String.t()) :: {:ok, map()} | {:error, Client.error()}
  def checks(repo, sha) do
    with {:ok, token} <- token(repo),
         {:ok, runs} <-
           Client.paginate(path(repo, "/commits/#{sha}/check-runs"),
             auth: {:token, token},
             key: "check_runs",
             max: @max_check_pages * 100
           ),
         {:ok, status} <- call(repo, :get, "/commits/#{sha}/status") do
      {:ok, %{runs: runs, statuses: status["statuses"] || []}}
    end
  end

  @doc """
  Compares `base...head`: `{:ok, status}` (`identical`, `ahead`, `behind`
  or `diverged`), `{:ok, :not_found}` when either does not exist.
  """
  @spec compare(repo(), String.t(), String.t()) ::
          {:ok, String.t() | :not_found} | {:error, Client.error()}
  def compare(repo, base, head) do
    case call(repo, :get, "/compare/#{encode(base)}...#{encode(head)}", params: [per_page: 1]) do
      {:ok, body} -> {:ok, body["status"]}
      {:error, :not_found} -> {:ok, :not_found}
      error -> error
    end
  end

  @doc "Where `refs/heads/<branch>` points: `{:ok, sha}` or `{:ok, nil}` when missing."
  @spec branch_head(repo(), String.t()) :: {:ok, String.t() | nil} | {:error, Client.error()}
  def branch_head(repo, branch) do
    case call(repo, :get, "/git/ref/heads/#{encode(branch)}") do
      {:ok, %{"object" => %{"sha" => sha}}} -> {:ok, sha}
      {:ok, _other} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  @doc "Deletes `refs/heads/<branch>`; already gone (404, 422) is success."
  @spec delete_branch(repo(), String.t()) :: :ok | {:error, Client.error()}
  def delete_branch(repo, branch) do
    case call(repo, :delete, "/git/refs/heads/#{encode(branch)}") do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, {:github_error, 422}} -> :ok
      error -> error
    end
  end

  defp call(repo, method, suffix, opts \\ []) do
    {per_page, opts} = Keyword.pop(opts, :per_page)

    opts =
      if per_page,
        do: Keyword.update(opts, :params, [per_page: per_page], &[{:per_page, per_page} | &1]),
        else: opts

    with {:ok, token} <- token(repo) do
      Client.request(method, path(repo, suffix), [auth: {:token, token}] ++ opts)
    end
  end

  defp path(%{repository: r}, suffix), do: "/repos/#{r.owner}/#{r.name}" <> suffix

  defp token(%{repository: repository, installation: installation}) do
    with {:ok, %{token: token}} <-
           Tokens.get(installation.installation_id, repository_ids: [repository.github_id]),
         do: {:ok, token}
  end

  # Branch names may hold `/`, which the ref and compare paths keep.
  defp encode(ref), do: URI.encode(ref, &(URI.char_unreserved?(&1) or &1 == ?/))
end
