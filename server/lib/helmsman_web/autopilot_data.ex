defmodule HelmsmanWeb.AutopilotData do
  @moduledoc """
  The autopilot domain functions the web layer uses (add-squads-autopilots-ui D13): thin
  wrappers of `Helmsman.Autopilots`, adapted to the shapes the pages use
  (`reviews/domain-request-1.md` R7):

  * `history/3` → `{:ok, %{records, more?}}` (asks the domain for one more record than
    the page size)
  * `run_now/3` → the new record as `get_run/2` reads it (the domain returns the row)
  * `enable_webhook/2`, `rotate_webhook_token/2` → `{:ok, %{token, url, autopilot}}`
  * `preview/3` errors → `%{cron: [msg]} | %{timezone: [msg]}`
  * `own?/2`: the views name people by their workspace identity (`%{name}`), so "the
    authorization source is me" compares that name with the scope's human identity
  """

  alias Helmsman.Autopilots

  defdelegate list(scope), to: Autopilots
  defdelegate get(scope, id), to: Autopilots
  defdelegate get_run(scope, record_id), to: Autopilots
  defdelegate create(scope, attrs), to: Autopilots
  defdelegate update(scope, id, attrs), to: Autopilots
  defdelegate enable(scope, id), to: Autopilots
  defdelegate disable(scope, id), to: Autopilots
  defdelegate delete(scope, id), to: Autopilots
  defdelegate disable_webhook(scope, id), to: Autopilots

  @doc """
  A page of records, newest first: `opts` `before_id` (exclusive cursor, nil for the
  first page) and `limit` (below the domain's maximum of 100).
  """
  def history(scope, id, opts) do
    limit = Keyword.get(opts, :limit, 50)

    case Autopilots.history(scope, id, before_id: opts[:before_id], limit: limit + 1) do
      {:ok, records} ->
        {:ok, %{records: Enum.take(records, limit), more?: length(records) > limit}}

      error ->
        error
    end
  end

  @doc "「立即运行」: `{:ok, record}` with the new record's view, or the domain's error."
  def run_now(scope, id, note) do
    case Autopilots.run_now(scope, id, note) do
      {:ok, %{id: record_id}} -> get_run(scope, record_id)
      error -> error
    end
  end

  def enable_webhook(scope, id), do: scope |> Autopilots.enable_webhook(id) |> with_url()

  def rotate_webhook_token(scope, id),
    do: scope |> Autopilots.rotate_webhook_token(id) |> with_url()

  defp with_url({:ok, %{token: token, autopilot: view}}),
    do: {:ok, %{token: token, url: view.webhook.url, autopilot: view}}

  defp with_url(error), do: error

  @doc "The next `count` times of `cron` in `timezone`, or `{:error, %{field => [msg]}}`."
  def preview(cron, timezone, count) do
    case Autopilots.preview(cron, timezone, count) do
      {:error, %Ecto.Changeset{} = cs} ->
        {:error, Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)}

      result ->
        result
    end
  end

  @doc "Whether the scope's user is the autopilot's authorization source."
  def own?(%{initiator: %{name: name}}, %{actor: %{kind: :human, name: name}}), do: true
  def own?(_view, _scope), do: false

  @doc "Subscribes the caller to the workspace's autopilot notifications."
  def subscribe(workspace_id), do: Helmsman.Events.subscribe(Autopilots.topic(workspace_id))
end
