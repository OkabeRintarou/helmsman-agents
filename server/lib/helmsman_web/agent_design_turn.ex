defmodule HelmsmanWeb.AgentDesignTurn do
  @moduledoc """
  The current turn of a creation conversation (add-agent-conversation-ui D5): its phase,
  the live text of its run, 停止 and the run link. The page keeps the state in
  `socket.assigns.turn` and forwards the run messages to `handle_info/2`.

  `sync/3` follows `view.current_run`: a new run is checked (`RunData.run/2`), its topic
  `run:<id>` subscribed, then its latest #{200} events read; later pushed events are
  appended by `seq`. Another run (or none) unsubscribes the previous one first.

  Only `text` events (Markdown, adjacent ones joined) and `tool_call` events (one line
  each, by tool) are kept; tool results, thinking and statuses never show. The state
  holds only that text, at most #{200} items.
  """
  use HelmsmanWeb, :html

  alias Helmsman.Events
  alias HelmsmanWeb.RunData

  @window 200
  @max_text 20_000

  @doc "No turn."
  def none, do: nil

  @doc """
  Follows `current_run` (`%{id, status}` or nil) of a fresh view: `turn` unchanged for
  the same run (status updated), else the old run unsubscribed and the new one opened.
  """
  def sync(turn, _scope, nil), do: close(turn)

  def sync(%{run_id: id} = turn, _scope, %{id: id, status: status}),
    do: %{turn | status: to_string(status)}

  def sync(turn, scope, %{id: id, status: status}) do
    close(turn)
    open(scope, id, to_string(status))
  end

  @doc "Unsubscribes the turn's run; returns nil."
  def close(nil), do: nil

  def close(%{topic: topic}) do
    if topic, do: Phoenix.PubSub.unsubscribe(Helmsman.PubSub, topic)
    nil
  end

  defp open(scope, id, status) do
    turn = %{run_id: id, status: status, topic: nil, items: [], max_seq: 0}

    case RunData.run(scope, id) do
      {:ok, _run} ->
        topic = Events.topic(:run, id)
        Events.subscribe(topic)
        turn = %{turn | topic: topic}

        case RunData.events(scope, id, latest: true, limit: @window) do
          {:ok, %{events: events, last_seq: last_seq}} ->
            %{add(turn, events) | max_seq: last_seq}

          _ ->
            turn
        end

      {:error, _} ->
        turn
    end
  end

  @doc """
  `{:run_events, id, events}` and `{:run_updated, summary}` of the turn's run:
  `{:ok, turn}`, or `:ignore` for other messages.
  """
  def handle_info({:run_events, id, events}, %{run_id: id} = turn),
    do: {:ok, add(turn, Enum.reject(events, &(&1.seq <= turn.max_seq)))}

  def handle_info({:run_updated, %{id: id, status: status}}, %{run_id: id} = turn),
    do: {:ok, %{turn | status: to_string(status)}}

  def handle_info(_message, _turn), do: :ignore

  defp add(turn, events) do
    items =
      events
      |> Enum.sort_by(& &1.seq)
      |> Enum.reduce(turn.items, &add_item/2)
      |> Enum.take(-@window)

    max_seq = Enum.reduce(events, turn.max_seq, &max(&1.seq, &2))
    %{turn | items: items, max_seq: max_seq}
  end

  defp add_item(%{type: "text", seq: seq, data: data}, items) do
    text = (data || %{})["text"] || ""

    # Adjacent texts join up to @max_text; beyond it a new item starts (the item window
    # drops the oldest), so the latest output always shows.
    case List.last(items) do
      %{kind: :text} = last when byte_size(last.text) + byte_size(text) <= @max_text ->
        List.replace_at(items, -1, %{last | text: last.text <> text})

      _ ->
        items ++ [%{seq: seq, kind: :text, text: latest(text)}]
    end
  end

  defp add_item(%{type: "tool_call", seq: seq, data: data}, items),
    do: items ++ [%{seq: seq, kind: :tool, text: tool_text(data || %{})}]

  defp add_item(_event, items), do: items

  defp latest(text) do
    if String.length(text) > @max_text, do: String.slice(text, -@max_text, @max_text), else: text
  end

  @doc "The line of a tool call (D5): by the tool's name without its `mcp__<server>__` prefix."
  def tool_text(data) do
    tool = data |> Map.get("name", "") |> to_string() |> String.replace(~r/^mcp__.+?__/, "")
    name = input_name(data["input"])

    case tool do
      "propose_agent" -> with_name(dgettext("ui", "更新了草稿"), name)
      "withdraw_agent" -> with_name(dgettext("ui", "从草稿移除了"), name, " ")
      "get_design" -> dgettext("ui", "读取了草稿")
      other -> dgettext("ui", "调用了 %{tool}", tool: other)
    end
  end

  defp with_name(text, name, sep \\ "：")
  defp with_name(text, nil, _sep), do: text
  defp with_name(text, name, sep), do: text <> sep <> name

  defp input_name(%{"name" => name}) when is_binary(name) and name != "", do: name

  defp input_name(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> input_name(map)
      _ -> nil
    end
  end

  defp input_name(_input), do: nil

  ## Rendering

  attr :turn, :map, required: true
  attr :helper, :string, required: true
  attr :scope, :map, required: true

  def turn(assigns) do
    ~H"""
    <div id="design-turn" class="mt-3 flex items-start gap-2" data-status={@turn.status}>
      <.actor_chip actor={%{name: @helper, kind: :agent}} compact />
      <div class="flex min-w-0 flex-1 flex-col gap-1.5 rounded-box border border-dashed border-border bg-surface px-3 py-2">
        <div class="flex flex-wrap items-center gap-2">
          <span id="design-turn-phase" class="text-label font-medium text-fg">
            {phase(@turn.status)}<span
              :if={@turn.status == "running"}
              class="ml-0.5 motion-safe:animate-pulse-soft"
            >…</span>
          </span>
          <span class="ml-auto flex items-center gap-1">
            <.link
              navigate={~p"/w/#{@scope.workspace.slug}/runs/#{@turn.run_id}"}
              target="_blank"
              id="design-turn-run"
              class="text-caption text-fg-muted hover:text-fg hover:underline"
            >
              {dgettext("ui", "执行记录")}
            </.link>
            <.button
              id="design-turn-stop"
              size="xs"
              variant="ghost"
              icon="lucide-circle-stop"
              phx-click="stop_turn"
              disabled={@turn.status == "cancelling"}
            >
              {dgettext("ui", "停止")}
            </.button>
          </span>
        </div>
        <p :if={@turn.status == "queued"} id="design-turn-queue" class="text-caption text-fg-muted">
          {dgettext("ui", "%{helper} 正忙或离线时最多等 10 分钟，之后这一轮会自动取消", helper: @helper)}
        </p>
        <div id="design-turn-items" class="flex flex-col gap-1.5">
          <%= for item <- @turn.items do %>
            <div :if={item.kind == :text} data-item="text">
              <.markdown content={item.text} scope={@scope} anchor_ns={"turn-#{item.seq}"} />
            </div>
            <p
              :if={item.kind == :tool}
              class="flex items-center gap-1 text-caption text-fg-muted"
              data-item="tool"
            >
              <.icon name="lucide-wrench" class="size-3" />{item.text}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp phase("queued"), do: dgettext("ui", "排队中")
  defp phase(status) when status in ~w(claimed deferred), do: dgettext("ui", "准备中")
  defp phase("running"), do: dgettext("ui", "正在回复")
  defp phase("cancelling"), do: dgettext("ui", "正在停止…")
  defp phase(_ended), do: dgettext("ui", "正在收尾…")
end
