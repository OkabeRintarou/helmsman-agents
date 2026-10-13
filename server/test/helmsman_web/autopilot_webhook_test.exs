defmodule HelmsmanWeb.AutopilotWebhookTest do
  # add-autopilots 6.2: POST /hooks/autopilots/:id (specs/autopilots
  # "Webhook 触发").
  use HelmsmanWeb.ConnCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AutopilotsFixtures

  alias Helmsman.{Autopilots, Repo}
  alias Helmsman.Autopilots.Workers.Prune
  alias Helmsman.Tasks.Task

  setup do
    ctx = autopilots_fixture()
    view = autopilot_fixture(ctx.alice_scope)
    {:ok, %{token: token}} = Autopilots.enable_webhook(ctx.bob_scope, view.id)
    Map.merge(ctx, %{view: view, token: token})
  end

  defp post_hook(id, token, body, headers \\ [], ctype \\ "application/json") do
    conn =
      Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn
    |> put_req_header("content-type", ctype)
    |> post("/hooks/autopilots/#{id}", body)
  end

  defp delivery(id), do: [{"x-delivery-id", id}]

  test "CI posts JSON: 202, a webhook record with the payload, bob its initiator", ctx do
    conn = post_hook(ctx.view.id, ctx.token, ~s({"build": 7}), delivery("d-1"))
    assert %{"id" => id, "status" => "started", "reason" => nil} = json_response(conn, 202)

    [record] = records_of(ctx.view)
    assert record.id == id

    assert {record.source, record.payload, record.delivery_id} ==
             {:webhook, %{"build" => 7}, "d-1"}

    assert record.initiator_user_id == ctx.bob.id
  end

  test "the same delivery the next day: 200 with the original, marked duplicate", ctx do
    first = json_response(post_hook(ctx.view.id, ctx.token, "{}", delivery("d-1")), 202)
    at(DateTime.add(DateTime.utc_now(), 86_400))
    again = json_response(post_hook(ctx.view.id, ctx.token, "{}", delivery("d-1")), 200)

    assert again == Map.put(first, "duplicate", true)
    assert length(records_of(ctx.view)) == 1
    assert Repo.aggregate(Task, :count) == 1
  end

  test "a wrong token and an unknown id answer the same 401", ctx do
    wrong = post_hook(ctx.view.id, "hma_" <> String.duplicate("A", 43), "{}")
    unknown = post_hook(999_999_999, ctx.token, "{}")
    missing = post_hook(ctx.view.id, nil, "{}")

    for conn <- [wrong, unknown, missing] do
      assert conn.status == 401
      assert conn.resp_body == ~s({"error":"unauthorized"})
    end
  end

  test "a skipped delivery re-sent a month later (after pruning) is still a duplicate", ctx do
    {:ok, _running} = Autopilots.run_now(ctx.alice_scope, ctx.view.id)

    assert %{"status" => "skipped", "reason" => "overlap"} =
             json_response(post_hook(ctx.view.id, ctx.token, "{}", delivery("d-7")), 202)

    at(DateTime.add(DateTime.utc_now(), 31 * 86_400))
    perform_job(Prune, %{})

    assert %{"duplicate" => true, "reason" => "overlap"} =
             json_response(post_hook(ctx.view.id, ctx.token, "{}", delivery("d-7")), 200)
  end

  test "after rotating, the old token gets 401; the new one works; bob the source", ctx do
    {:ok, %{token: new}} = Autopilots.rotate_webhook_token(ctx.bob_scope, ctx.view.id)
    assert post_hook(ctx.view.id, ctx.token, "{}").status == 401
    assert post_hook(ctx.view.id, new, "{}").status == 202
    assert autopilot_row(ctx.view).initiator_user_id == ctx.bob.id
  end

  test "the 11th authenticated request in a minute: 429 with retry-after, no record", ctx do
    {:ok, _running} = Autopilots.run_now(ctx.alice_scope, ctx.view.id)

    for i <- 1..10,
        do: assert(post_hook(ctx.view.id, ctx.token, "{}", delivery("r-#{i}")).status == 202)

    conn = post_hook(ctx.view.id, ctx.token, "{}", delivery("r-11"))
    assert conn.status == 429
    assert [retry] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) in 1..60
    refute Enum.any?(records_of(ctx.view), &(&1.delivery_id == "r-11"))
  end

  test "a 200 KB JSON body: 202, stored as text cut to 64 KB", ctx do
    body = Jason.encode!(%{"log" => String.duplicate("x", 200_000)})
    assert post_hook(ctx.view.id, ctx.token, body).status == 202
    [record] = records_of(ctx.view)
    assert %{"raw" => raw, "truncated" => true} = record.payload
    assert byte_size(raw) == 65_536
  end

  test "disabled: 409", ctx do
    {:ok, _} = Autopilots.disable(ctx.alice_scope, ctx.view.id)
    conn = post_hook(ctx.view.id, ctx.token, "{}")
    assert json_response(conn, 409) == %{"error" => "disabled"}
  end

  test "an X-Delivery-Id with a newline or over 200 bytes: 400", ctx do
    assert post_hook(ctx.view.id, ctx.token, "{}", delivery("a\nb")).status == 400

    assert post_hook(ctx.view.id, ctx.token, "{}", delivery(String.duplicate("x", 201))).status ==
             400

    assert records_of(ctx.view) == []
  end

  test "1 MB and one byte: 413", ctx do
    body = String.duplicate("x", 1024 * 1024 + 1)
    assert post_hook(ctx.view.id, ctx.token, body, [], "text/plain").status == 413
    assert records_of(ctx.view) == []
  end
end
