defmodule HelmsmanWeb.GitHubWebhookTest do
  # One test removes the GitHub App environment variables.
  use HelmsmanWeb.ConnCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.GitHubFixtures

  alias Helmsman.GitHub.Delivery
  alias Helmsman.GitHub.Workers.HandleWebhook
  alias Helmsman.Repo

  defp deliver(conn, body, headers) do
    headers
    |> Enum.reduce(put_req_header(conn, "content-type", "application/json"), fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
    |> post("/webhooks/github", body)
  end

  defp headers(body, delivery_id, event \\ "installation_repositories") do
    [
      {"x-github-delivery", delivery_id},
      {"x-github-event", event},
      {"x-hub-signature-256", sign(body)}
    ]
  end

  @body ~s({"action":"added","installation":{"id":1}})

  test "a body changed by one byte → 401, nothing recorded or queued", %{conn: conn} do
    tampered = String.replace(@body, "added", "addee")
    conn = deliver(conn, tampered, headers(@body, "d-1"))

    assert conn.status == 401
    refute Repo.exists?(Delivery)
    refute_enqueued(worker: HandleWebhook)
  end

  test "a duplicate delivery → 202 then 200, one job", %{conn: conn} do
    assert deliver(conn, @body, headers(@body, "d-2")).status == 202
    assert deliver(build_conn(), @body, headers(@body, "d-2")).status == 200

    assert [job] = all_enqueued(worker: HandleWebhook)
    assert job.args["delivery_id"] == "d-2"
    assert job.args["event"] == "installation_repositories"
    assert job.args["payload"]["installation"]["id"] == 1
  end

  test "ping and unhandled events are recorded, accepted and do nothing", %{conn: conn} do
    body = ~s({"zen":"Keep it logically awesome.","hook_id":1})

    assert deliver(conn, body, headers(body, "d-3", "ping")).status == 202
    assert Repo.get(Delivery, "d-3").event == "ping"

    assert [job] = all_enqueued(worker: HandleWebhook)
    assert :ok = perform_job(HandleWebhook, job.args)
    assert [] = all_enqueued(worker: HandleWebhook) -- [job]
  end

  test "a missing delivery ID or event → 400", %{conn: conn} do
    [delivery, event, signature] = headers(@body, "d-4")
    assert deliver(conn, @body, [event, signature]).status == 400
    assert deliver(build_conn(), @body, [delivery, signature]).status == 400
    refute Repo.exists?(Delivery)
  end

  test "a missing signature → 401", %{conn: conn} do
    [delivery, event, _signature] = headers(@body, "d-5")
    assert deliver(conn, @body, [delivery, event]).status == 401
  end

  test "no App configured → 503", %{conn: conn} do
    headers = headers(@body, "d-6")
    without_app_env()
    assert deliver(conn, @body, headers).status == 503
    refute Repo.exists?(Delivery)
  end

  test "a 26 MB body → 413", %{conn: conn} do
    body = String.duplicate("a", 26 * 1024 * 1024)
    assert deliver(conn, body, headers(body, "d-7")).status == 413
    refute Repo.exists?(Delivery)
  end

  test "other JSON requests are still parsed by Plug.Parsers" do
    conn =
      Plug.Test.conn(:post, "/somewhere", ~s({"a":1}))
      |> put_req_header("content-type", "application/json")
      |> HelmsmanWeb.GitHubWebhookPlug.call([])

    refute conn.halted

    parsers =
      Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

    assert Plug.Parsers.call(conn, parsers).body_params == %{"a" => 1}
  end
end
