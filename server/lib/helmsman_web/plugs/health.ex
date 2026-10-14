defmodule HelmsmanWeb.Plugs.Health do
  @moduledoc """
  Health checks (`add-release-distribution` decision 4), first in the
  endpoint: no SSL redirect, session, CSRF, router, telemetry or request
  log, no authentication.

    * `GET /healthz` - 200 `{"status":"ok"}` while the VM serves requests;
      never touches the database (the container health check).
    * `GET /readyz` - 200 with the version when the database answers
      `SELECT 1` within 2 seconds and Oban runs with none of its queues
      paused; otherwise 503 with the failing checks as `"error"` (never
      the reason).

  Only `GET` and `HEAD` are answered; other methods fall through to the
  router.
  """

  @behaviour Plug

  import Plug.Conn

  alias Helmsman.Repo

  @db_timeout 2_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["healthz"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    respond(conn, 200, %{status: "ok"})
  end

  def call(%Plug.Conn{method: method, path_info: ["readyz"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    checks = %{database: check(&database/0), oban: check(&oban/0)}
    ok? = Enum.all?(checks, fn {_name, result} -> result == "ok" end)

    respond(conn, if(ok?, do: 200, else: 503), %{
      status: if(ok?, do: "ok", else: "error"),
      version: version(),
      checks: checks
    })
  end

  def call(conn, _opts), do: conn

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp check(fun) do
    if fun.(), do: "ok", else: "error"
  catch
    _kind, _reason -> "error"
  end

  # Bounded as a whole: a connection attempt that hangs is cut at 2 seconds.
  defp database do
    task = Task.async(fn -> select_one() end)

    case Task.yield(task, @db_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{rows: [[1]]}}} -> true
      _ -> false
    end
  end

  # Never raises: the task is linked to the request process.
  defp select_one do
    Repo.query("SELECT 1", [], timeout: @db_timeout, log: false)
  catch
    kind, reason -> {kind, reason}
  end

  defp oban do
    %{queues: queues} = Oban.config(Oban)

    is_pid(Oban.whereis(Oban)) and
      Enum.all?(queues, fn {queue, _opts} ->
        match?(%{paused: false}, Oban.check_queue(Oban, queue: queue))
      end)
  end

  defp version, do: :helmsman |> Application.spec(:vsn) |> to_string()
end
