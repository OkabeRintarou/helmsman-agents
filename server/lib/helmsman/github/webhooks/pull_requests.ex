defmodule Helmsman.GitHub.Webhooks.PullRequests do
  @moduledoc """
  Pull request and check events (`pull_request`, `check_suite`,
  `check_run`, `status`) only wake the reconciliation of the tasks they
  are about (`add-pr-reconcile-merge` decision 13); their payloads are
  never written.

  The repository is the instance's not removed row for the payload's
  `repository.id`. A `pull_request` event finds its task by the recorded
  `(repository, number)`, else by the head branch `hm/<workspace
  ID>/<ident>` of the repository's workspace; check events by the pull
  request numbers they list and their head commit, `status` by its
  commit, among draft and open pull requests. Only tasks whose project is
  bound to that repository now are woken (decision 20); anything else is
  ignored.
  """

  import Ecto.Query, warn: false

  alias Helmsman.GitHub.{PullRequest, PullRequests, Repository}
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Tasks.{Ident, Task}

  @doc "Handles a pull request or check event."
  @spec handle(String.t(), map()) :: :ok
  def handle(event, payload) do
    for repository <- repositories(payload),
        task_id <- event |> tasks(payload, repository) |> Enum.uniq(),
        bound?(task_id, repository) do
      PullRequests.wake(task_id)
    end

    :ok
  end

  defp repositories(%{"repository" => %{"id" => github_id}}) when is_integer(github_id),
    do: Repo.all(from(r in Repository, where: r.github_id == ^github_id and is_nil(r.removed_at)))

  defp repositories(_payload), do: []

  defp tasks("pull_request", %{"pull_request" => %{} = pr}, repository) do
    case by_numbers(repository, [pr["number"]]) do
      [] -> by_branch(repository, get_in(pr, ["head", "ref"]))
      ids -> ids
    end
  end

  defp tasks("check_suite", %{"check_suite" => %{} = suite}, repository),
    do: by_check(repository, suite)

  defp tasks("check_run", %{"check_run" => %{} = run}, repository),
    do: by_check(repository, run)

  defp tasks("status", %{"sha" => sha}, repository), do: by_head(repository, sha)
  defp tasks(_event, _payload, _repository), do: []

  defp by_check(repository, object) do
    numbers = for %{"number" => n} <- List.wrap(object["pull_requests"]), do: n
    by_numbers(repository, numbers) ++ by_head(repository, object["head_sha"])
  end

  defp by_numbers(repository, numbers) do
    numbers = Enum.filter(numbers, &is_integer/1)

    Repo.all(
      from(p in PullRequest,
        where: p.repository_id == ^repository.id and p.number in ^numbers,
        select: p.task_id
      )
    )
  end

  defp by_head(repository, sha) when is_binary(sha) do
    Repo.all(
      from(p in PullRequest,
        where:
          p.repository_id == ^repository.id and p.head_sha == ^sha and
            p.state in [:draft, :open],
        select: p.task_id
      )
    )
  end

  defp by_head(_repository, _sha), do: []

  # `hm/<workspace ID>/<ident in lower case>`, of the repository's workspace.
  defp by_branch(repository, "hm/" <> rest) do
    workspace_id = Integer.to_string(repository.workspace_id)

    with [^workspace_id, name] <- String.split(rest, "/", parts: 2),
         {:ok, ident, _key, _seq} <- Ident.parse(name),
         id when is_integer(id) <-
           Repo.one(
             from(t in Task,
               where: t.workspace_id == ^repository.workspace_id and t.ident == ^ident,
               select: t.id
             )
           ) do
      [id]
    else
      _ -> []
    end
  end

  defp by_branch(_repository, _ref), do: []

  defp bound?(task_id, repository) do
    Repo.exists?(
      from(t in Task,
        join: p in Project,
        on: p.id == t.project_id,
        where: t.id == ^task_id and p.repository_id == ^repository.id
      )
    )
  end
end
