defmodule HelmsmanWeb.API.AutopilotsControllerTest do
  # add-rest-api 7.1 / decision 13: POST /autopilots/:id/run.
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.AutopilotsFixtures
  import Helmsman.RunsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.Autopilots.Autopilot
  alias Helmsman.Repo

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = autopilots_fixture()
    view = autopilot_fixture(ctx.alice_scope)

    Map.merge(ctx, %{
      view: view,
      slug: ctx.workspace.slug,
      token: token_for(ctx.alice, ctx.workspace)
    })
  end

  # Every test has one workspace, whose slug the setup keeps here.
  defp run(token, id, body \\ nil, headers \\ []),
    do: api_send(:post, token, w(Process.get(:slug), "/autopilots/#{id}/run"), body, headers)

  setup ctx do
    Process.put(:slug, ctx.slug)
    :ok
  end

  defp disable!(view),
    do:
      Repo.update_all(from(a in Autopilot, where: a.id == ^view.id),
        set: [enabled: false, disabled_reason: :manual]
      )

  test "a member who may trigger the target runs a disabled autopilot: 202, it stays disabled",
       ctx do
    disable!(ctx.view)
    token = token_for(ctx.bob, ctx.workspace)

    data = token |> run(ctx.view.id, %{instructions: "try it"}) |> body!(202)
    assert_schema(data["data"], "AutopilotRecord", ctx.spec)
    assert %{"id" => id, "status" => "started", "reason" => nil} = data["data"]

    assert [%{id: ^id, source: :manual, note: "try it", initiator_user_id: bob_id}] =
             records_of(ctx.view)

    assert bob_id == ctx.bob.id
    assert autopilot_row(ctx.view).enabled == false
  end

  test "always as the token's user: with or without a default agent", ctx do
    %{token: with_default} = api_token_fixture(ctx.alice_scope, %{default_agent_id: ctx.agent.id})

    for token <- [with_default, ctx.token] do
      assert token |> run(ctx.view.id) |> body!(202)
    end

    records = records_of(ctx.view)
    assert length(records) == 2
    assert Enum.all?(records, &(&1.initiator_user_id == ctx.alice.id))
  end

  test "an agent as X-Helmsman-Actor or actor is 403, nothing recorded; one's human name is fine",
       ctx do
    ctx.token
    |> run(ctx.view.id, nil, [{"x-helmsman-actor", "keel/dev"}])
    |> error!(403, "forbidden")

    ctx.token |> run(ctx.view.id, %{actor: "keel/dev"}) |> error!(403, "forbidden")
    assert records_of(ctx.view) == []

    human = human_actor(ctx.workspace, ctx.alice)
    assert ctx.token |> run(ctx.view.id, nil, [{"x-helmsman-actor", human.name}]) |> body!(202)
  end

  test "instructions over 4 KB are 422 on instructions; not a string 400", ctx do
    detail =
      ctx.token
      |> run(ctx.view.id, %{instructions: String.duplicate("é", 2049)})
      |> error!(422, "validation_failed")

    assert %{"fields" => %{"instructions" => [_]}} = detail

    ctx.token |> run(ctx.view.id, %{instructions: 7}) |> error!(400, "invalid_params")
    assert records_of(ctx.view) == []
  end

  test "a member who may not trigger the target: 403 forbidden, no record", ctx do
    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/triage",
      runtime_id: profile(ctx.agent).runtime_id,
      access: "owner_only"
    })

    view = autopilot_fixture(ctx.alice_scope, %{agent: "keel/triage"})
    token = token_for(ctx.bob, ctx.workspace)

    token |> run(view.id) |> error!(403, "forbidden")
    assert records_of(view) == []
  end

  test "a viewer: 403; an unknown or malformed id: 404", ctx do
    {_viewer, viewer} = member_token(ctx.workspace, :viewer)
    viewer |> run(ctx.view.id) |> error!(403, "forbidden")
    assert records_of(ctx.view) == []

    for id <- ["999999999", "0", "abc"] do
      ctx.token |> run(id) |> error!(404, "not_found")
    end
  end

  test "the domain is called without an open transaction", ctx do
    parent = self()
    Process.put(:helmsman_test_hook, fn point -> send(parent, {:hook, point}) end)

    assert ctx.token |> run(ctx.view.id) |> body!(202)
    assert_received {:hook, {:run_now, false}}
  end
end

defmodule HelmsmanWeb.API.AutopilotsConcurrencyTest do
  # add-rest-api 7.1: "run now" over REST interleaved with saving and
  # disabling the same autopilot (test-hook barriers, each side on a
  # connection of its own): both finish, no deadlock.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.ApiTokensFixtures
  import Helmsman.AutopilotsFixtures
  import HelmsmanWeb.APIHelpers

  alias Helmsman.{Autopilots, CommittedData, Repo}
  alias Helmsman.Autopilots.Record

  @moduletag timeout: 60_000
  @wait 5_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = autopilots_fixture()
        %{token: token} = api_token_fixture(ctx.alice_scope, %{default_agent_id: ctx.agent.id})
        Map.merge(ctx, %{token: token, view: autopilot_fixture(ctx.alice_scope)})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id]) end)
    ctx
  end

  defp side(fun, pause \\ nil) do
    parent = self()

    task =
      Task.async(fn ->
        CommittedData.unboxed(fn -> run_side(fun, parent, pause) end)
      end)

    assert_receive {:backend, pid, backend}, @wait
    %{task: task, pid: pid, backend: backend}
  end

  defp run_side(fun, parent, pause) do
    send(parent, {:backend, self(), CommittedData.backend_pid()})
    if pause, do: Process.put(:helmsman_test_hook, &hook(&1, parent, pause))
    fun.()
  end

  defp hook(pause, parent, pause), do: pause_once(parent)
  defp hook({:run_now, in_tx}, parent, _pause), do: send(parent, {:run_now_in_tx, in_tx})
  defp hook(_point, _parent, _pause), do: :ok

  defp pause_once(parent) do
    if Process.get(:paused) == nil do
      Process.put(:paused, true)
      send(parent, {:paused, self()})
      receive do: (:continue -> :ok)
    end
  end

  defp rest_run(ctx) do
    fn ->
      conn = api_send(:post, ctx.token, w(ctx.workspace.slug, "/autopilots/#{ctx.view.id}/run"))
      {conn.status, Jason.decode!(conn.resp_body)}
    end
  end

  defp records(id),
    do:
      CommittedData.unboxed(fn ->
        Repo.all(from(r in Record, where: r.autopilot_id == ^id, order_by: r.id))
      end)

  test "REST holds the autopilot row; disabling waits for it, then both finish", ctx do
    rest = side(rest_run(ctx), {:locked, :manual})
    assert_receive {:run_now_in_tx, false}, @wait
    assert_receive {:paused, pid} when pid == rest.pid, @wait

    disable = side(fn -> Autopilots.disable(ctx.alice_scope, ctx.view.id) end)
    CommittedData.await_lock_wait(disable.backend)
    send(rest.pid, :continue)

    assert {202, %{"data" => %{"status" => "started"}}} = Task.await(rest.task, @wait)
    assert {:ok, _id} = Task.await(disable.task, @wait)

    assert [%Record{source: :manual, initiator_user_id: alice_id}] = records(ctx.view.id)
    assert alice_id == ctx.alice.id
    refute CommittedData.unboxed(fn -> autopilot_row(ctx.view).enabled end)
  end

  test "a save commits while REST waits before the autopilot lock; then REST runs", ctx do
    rest = side(rest_run(ctx), {:accept, :manual})
    assert_receive {:paused, pid} when pid == rest.pid, @wait

    save = side(fn -> Autopilots.update(ctx.alice_scope, ctx.view.id, %{name: "renamed"}) end)
    assert {:ok, %{name: "renamed"}} = Task.await(save.task, @wait)
    send(rest.pid, :continue)

    assert {202, %{"data" => %{"status" => "started"}}} = Task.await(rest.task, @wait)
    assert [%Record{initiator_user_id: alice_id}] = records(ctx.view.id)
    assert alice_id == ctx.alice.id
  end
end
