defmodule Helmsman.FakeGitHub do
  @moduledoc """
  A stateful GitHub for the pull request tests (`add-pr-reconcile-merge`),
  behind the `Req.Test` stub of `Helmsman.GitHub.Client`. Response bodies
  start from `test/support/fixtures/github/*.json` (see `SOURCE.md`) with
  the fields of the fake's state filled in.

  The state: pull requests by number (`pulls`), branches (`refs`), check
  runs and statuses by commit, compare results by `{base, head}`
  (`compare`, default `"behind"`), queued answers for `POST /pulls` and
  `PUT /merge` (`create_errors`, `merge_answers`) and the log of every
  request (`requests/1`). A request made inside a database transaction
  fails the test.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions

  @dir Path.expand("fixtures/github", __DIR__)

  @doc "Starts a fake for `owner/name` and installs the stub; returns the fake."
  def start(owner \\ "acme", name \\ "app", state \\ %{}) do
    {:ok, fake} =
      Agent.start_link(fn ->
        Map.merge(
          %{
            owner: owner,
            name: name,
            pulls: %{},
            next_number: 1,
            refs: %{},
            checks: %{},
            statuses: %{},
            compare: %{},
            create_errors: [],
            merge_answers: [],
            fail: nil,
            fail_create_ref: false,
            log: []
          },
          state
        )
      end)

    Req.Test.stub(Helmsman.GitHub.Client, &handle(fake, &1))
    fake
  end

  @doc "Updates the fake's state with `fun`."
  def update(fake, fun), do: Agent.update(fake, fun)

  @doc "Reads the fake's state."
  def get(fake), do: Agent.get(fake, & &1)

  @doc "Adds pull request `number` with `attrs` (`head_sha`, `head_ref`, `state`, ...)."
  def put_pull(fake, number, attrs) do
    update(fake, fn s ->
      pull =
        Map.merge(
          %{
            number: number,
            state: "open",
            draft: false,
            merged: false,
            head_ref: nil,
            head_sha: nil,
            base: "main",
            mergeable: true,
            mergeable_state: "clean",
            merge_commit_sha: nil,
            title: ""
          },
          Map.new(attrs)
        )

      %{s | pulls: Map.put(s.pulls, number, pull), next_number: max(s.next_number, number + 1)}
    end)
  end

  @doc "Changes pull request `number`."
  def change_pull(fake, number, attrs),
    do: update(fake, fn s -> update_in(s.pulls[number], &Map.merge(&1, Map.new(attrs))) end)

  @doc "Pull request `number` as the fake holds it."
  def pull(fake, number), do: get(fake).pulls[number]

  @doc "Every request `{method, path}` so far, oldest first."
  def requests(fake),
    do: get(fake).log |> Enum.reverse() |> Enum.map(&Map.take(&1, [:method, :path]))

  @doc "The requests with their decoded JSON bodies."
  def requests_with_bodies(fake), do: Enum.reverse(get(fake).log)

  @doc "Whether a request matched `method` and a path ending with `suffix`."
  def requested?(fake, method, suffix),
    do: Enum.any?(requests(fake), &(&1.method == method and String.ends_with?(&1.path, suffix)))

  @doc "A check run as the API returns it."
  def check_run(name, conclusion, extra \\ %{}) do
    Map.merge(
      %{
        "id" => System.unique_integer([:positive]),
        "name" => name,
        "status" => if(conclusion, do: "completed", else: "in_progress"),
        "conclusion" => conclusion,
        "details_url" => "https://github.com/acme/app/actions/runs/1",
        "output" => %{"title" => nil, "summary" => nil}
      },
      extra
    )
  end

  defp fixture(name), do: @dir |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()

  ## The stub

  defp handle(fake, conn) do
    if Helmsman.Repo.in_transaction?(), do: flunk("GitHub was called inside a transaction")

    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)

    update(fake, fn s ->
      %{
        s
        | log: [
            %{method: conn.method, path: conn.request_path, query: conn.query_params, body: body}
            | s.log
          ]
      }
    end)

    case get(fake).fail do
      fun when is_function(fun, 2) ->
        case fun.(conn.method, conn.request_path) do
          nil -> route(fake, conn, body)
          {status, json} -> reply(conn, status, json)
        end

      _ ->
        route(fake, conn, body)
    end
  end

  defp route(fake, conn, body) do
    %{owner: owner, name: name} = get(fake)
    prefix = "/repos/#{owner}/#{name}"

    case {conn.method, conn.request_path} do
      {"POST", "/app/installations/" <> _} ->
        expires = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        reply(conn, 201, %{"token" => "ghs_fake_installation_token", "expires_at" => expires})

      {"POST", "/graphql"} ->
        graphql(fake, conn, body)

      {method, ^prefix <> rest} ->
        repo(fake, conn, method, rest, body)

      _ ->
        reply(conn, 404, %{"message" => "Not Found"})
    end
  end

  defp repo(fake, conn, "GET", "/pulls", _body) do
    s = get(fake)
    %{"head" => head, "base" => base, "state" => "open"} = conn.query_params
    branch = String.replace_prefix(head, "#{s.owner}:", "")

    prs =
      for {_n, p} <- Enum.sort(s.pulls),
          p.head_ref == branch and p.base == base and p.state == "open",
          do: render(fake, p)

    reply(conn, 200, prs)
  end

  defp repo(fake, conn, "POST", "/pulls", body) do
    s = get(fake)

    case s.create_errors do
      [error | rest] ->
        update(fake, &%{&1 | create_errors: rest})
        reply(conn, 422, fixture("create_422_#{error}"))

      [] ->
        cond do
          not Map.has_key?(s.refs, body["head"]) ->
            reply(conn, 422, fixture("create_422_head"))

          Enum.any?(s.pulls, fn {_n, p} ->
            p.head_ref == body["head"] and p.base == body["base"] and p.state == "open"
          end) ->
            reply(conn, 422, fixture("create_422_exists"))

          true ->
            n = s.next_number

            put_pull(fake, n, %{
              head_ref: body["head"],
              head_sha: s.refs[body["head"]],
              base: body["base"],
              draft: body["draft"] == true,
              title: body["title"],
              body: body["body"]
            })

            reply(conn, 201, render(fake, pull(fake, n)))
        end
    end
  end

  defp repo(fake, conn, method, "/pulls/" <> rest, body) do
    case {method, String.split(rest, "/")} do
      {"GET", [n]} -> with_pull(fake, conn, n, &reply(conn, 200, render(fake, &1)))
      {"PATCH", [n]} -> with_pull(fake, conn, n, &patch(fake, conn, &1, body))
      {"PUT", [n, "merge"]} -> with_pull(fake, conn, n, &merge(fake, conn, &1, body))
      _ -> reply(conn, 404, %{"message" => "Not Found"})
    end
  end

  defp repo(fake, conn, "GET", "/commits/" <> rest, _body) do
    s = get(fake)

    case String.split(rest, "/") do
      [sha, "check-runs"] ->
        runs = Map.get(s.checks, sha, [])
        reply(conn, 200, %{"total_count" => length(runs), "check_runs" => runs})

      [sha, "status"] ->
        statuses = Map.get(s.statuses, sha, [])
        reply(conn, 200, fixture("status") |> Map.merge(%{"sha" => sha, "statuses" => statuses}))
    end
  end

  defp repo(fake, conn, "GET", "/compare/" <> spec, _body) do
    [base, head] = String.split(URI.decode(spec), "...")

    case Map.get(get(fake).compare, {base, head}, "behind") do
      :not_found -> reply(conn, 404, %{"message" => "Not Found"})
      status -> reply(conn, 200, Map.put(fixture("compare"), "status", status))
    end
  end

  defp repo(fake, conn, "GET", "/git/ref/heads/" <> branch, _body) do
    branch = URI.decode(branch)

    case get(fake).refs[branch] do
      nil -> reply(conn, 404, %{"message" => "Not Found"})
      sha -> reply(conn, 200, ref_body(branch, sha))
    end
  end

  defp repo(fake, conn, "DELETE", "/git/refs/heads/" <> branch, _body) do
    branch = URI.decode(branch)

    if Map.has_key?(get(fake).refs, branch) do
      update(fake, &%{&1 | refs: Map.delete(&1.refs, branch)})
      Plug.Conn.send_resp(conn, 204, "")
    else
      reply(conn, 422, fixture("ref_422"))
    end
  end

  defp repo(fake, conn, "POST", "/git/refs", %{"ref" => "refs/heads/" <> branch, "sha" => sha}) do
    if get(fake).fail_create_ref do
      reply(conn, 422, %{"message" => "Object does not exist"})
    else
      update(fake, &%{&1 | refs: Map.put(&1.refs, branch, sha)})
      reply(conn, 201, ref_body(branch, sha))
    end
  end

  defp repo(_fake, conn, _method, _rest, _body), do: reply(conn, 404, %{"message" => "Not Found"})

  defp with_pull(fake, conn, n, fun) do
    case pull(fake, String.to_integer(n)) do
      nil -> reply(conn, 404, %{"message" => "Not Found"})
      p -> fun.(p)
    end
  end

  defp patch(fake, conn, p, %{"state" => state}) do
    change_pull(fake, p.number, state: state)
    reply(conn, 200, render(fake, pull(fake, p.number)))
  end

  defp merge(fake, conn, p, %{"sha" => sha} = body) do
    case get(fake).merge_answers do
      [answer | rest] ->
        update(fake, &%{&1 | merge_answers: rest})
        merge_answer(fake, conn, p, answer)

      [] ->
        if sha == p.head_sha do
          merged = String.duplicate("e", 40)
          change_pull(fake, p.number, merged: true, state: "closed", merge_commit_sha: merged)
          update(fake, &Map.put(&1, :last_merge, body))
          reply(conn, 200, fixture("merge_200") |> Map.put("sha", merged))
        else
          reply(conn, 409, fixture("merge_409"))
        end
    end
  end

  defp merge_answer(fake, conn, p, :conflict) do
    change_pull(fake, p.number, mergeable: false, mergeable_state: "dirty")
    reply(conn, 405, fixture("merge_405_conflict"))
  end

  defp merge_answer(_fake, conn, _p, :checks), do: reply(conn, 405, fixture("merge_405_checks"))

  defp merge_answer(_fake, conn, _p, {:rejected, message}),
    do: reply(conn, 405, %{"message" => message})

  defp merge_answer(_fake, conn, _p, :head_changed), do: reply(conn, 409, fixture("merge_409"))

  defp graphql(fake, conn, %{"query" => query, "variables" => %{"id" => "PR_node_" <> n}}) do
    n = String.to_integer(n)

    cond do
      pull(fake, n) == nil ->
        reply(conn, 200, %{"errors" => [%{"message" => "Could not resolve to a node"}]})

      query =~ "convertPullRequestToDraft" ->
        change_pull(fake, n, draft: true)
        reply(conn, 200, fixture("graphql_draft"))

      query =~ "markPullRequestReadyForReview" ->
        change_pull(fake, n, draft: false)
        reply(conn, 200, fixture("graphql_ready"))
    end
  end

  defp render(fake, p) do
    %{owner: owner, name: name} = get(fake)

    fixture("pull")
    |> Map.merge(%{
      "number" => p.number,
      "node_id" => "PR_node_#{p.number}",
      "html_url" => "https://github.com/#{owner}/#{name}/pull/#{p.number}",
      "url" => "https://api.github.com/repos/#{owner}/#{name}/pulls/#{p.number}",
      "state" => p.state,
      "draft" => p.draft,
      "merged" => p.merged,
      "merged_at" => if(p.merged, do: "2026-10-13T00:00:00Z"),
      "merge_commit_sha" => p.merge_commit_sha,
      "mergeable" => p.mergeable,
      "mergeable_state" => p.mergeable_state,
      "title" => p.title,
      "head" => %{"label" => "#{owner}:#{p.head_ref}", "ref" => p.head_ref, "sha" => p.head_sha},
      "base" => %{
        "label" => "#{owner}:#{p.base}",
        "ref" => p.base,
        "sha" => String.duplicate("0", 40)
      }
    })
  end

  defp ref_body(branch, sha) do
    fixture("ref")
    |> Map.merge(%{
      "ref" => "refs/heads/" <> branch,
      "object" => %{"sha" => sha, "type" => "commit"}
    })
  end

  defp reply(conn, status, json), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
end
