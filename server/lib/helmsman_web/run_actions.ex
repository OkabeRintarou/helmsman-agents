defmodule HelmsmanWeb.RunActions do
  @moduledoc """
  停止 and 重试 of runs (spec web-runs 停止与重试, design D8), shared by the task page, the
  agent page and the run page. The host keeps `socket.assigns.stop_run` (the run whose
  stop is being confirmed), forwards `ask_cancel_run`, `cancel_run`, `dismiss_cancel_run`
  and `retry_run`, and renders `dialog/1`. After an action `reload` (a function of the
  socket) refreshes the host's runs.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.RunData

  @doc "Adds the state."
  def init(socket), do: Phoenix.Component.assign(socket, :stop_run, nil)

  @doc "Handles a run action event; returns the socket."
  def handle_event("ask_cancel_run", %{"id" => id}, socket, _reload) do
    with {:ok, id} <- parse(id),
         {:ok, run} <- RunData.run(socket.assigns.current_scope, id) do
      Phoenix.Component.assign(socket, :stop_run, %{id: run.id, agent: run.agent})
    else
      _ -> socket
    end
  end

  def handle_event("dismiss_cancel_run", _params, socket, _reload),
    do: Phoenix.Component.assign(socket, :stop_run, nil)

  def handle_event("cancel_run", %{"id" => id}, socket, reload) do
    socket = Phoenix.Component.assign(socket, :stop_run, nil)

    with {:ok, id} <- parse(id),
         {:ok, _run} <- RunData.cancel(socket.assigns.current_scope, id) do
      reload.(socket)
    else
      {:error, reason} -> socket |> put_flash(:error, refusal(reason, id, socket)) |> reload.()
      :error -> socket
    end
  end

  def handle_event("retry_run", %{"id" => id}, socket, reload) do
    with {:ok, id} <- parse(id),
         {:ok, _run} <- RunData.retry(socket.assigns.current_scope, id) do
      socket |> put_flash(:info, dgettext("ui", "已重新排队")) |> reload.()
    else
      {:error, reason} -> socket |> put_flash(:error, refusal(reason, id, socket)) |> reload.()
      :error -> socket
    end
  end

  defp parse(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp put_flash(socket, kind, text), do: Phoenix.LiveView.put_flash(socket, kind, text)

  # The agent's name is read only for the refusals that name it.
  defp refusal(reason, id, socket) when reason in [:agent_disabled, :agent_archived] do
    agent =
      case RunData.run(socket.assigns.current_scope, id) do
        {:ok, run} -> run.agent
        _ -> nil
      end

    error_text(reason, agent)
  end

  defp refusal(reason, _id, _socket), do: error_text(reason)

  @doc "Text of a refused stop or retry (`agent`: the run's agent, for the agent refusals)."
  def error_text(reason, agent \\ nil)
  def error_text(:already_finished, _), do: dgettext("ui", "运行已经结束")

  def error_text({:already_retried, id}, _),
    do: dgettext("ui", "这次运行已经重试过（#%{id}）", id: id)

  def error_text(:task_closed, _), do: dgettext("ui", "任务已验收或撤销，不能重试")
  def error_text(:agent_disabled, nil), do: dgettext("ui", "Agent 已停用")
  def error_text(:agent_disabled, agent), do: dgettext("ui", "%{agent} 已停用", agent: agent)
  def error_text(:agent_archived, nil), do: dgettext("ui", "Agent 已归档")
  def error_text(:agent_archived, agent), do: dgettext("ui", "%{agent} 已归档", agent: agent)
  def error_text(:forbidden, _), do: dgettext("ui", "没有权限执行此操作")
  def error_text(:not_found, _), do: dgettext("ui", "运行不存在")
  def error_text(_reason, _), do: dgettext("ui", "操作失败，请稍后重试")

  attr :stop_run, :map, default: nil

  def dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="stop-run"
      show={@stop_run != nil}
      danger
      title={if(@stop_run, do: dgettext("ui", "停止运行 #%{id}？", id: @stop_run.id), else: "")}
      confirm_label={dgettext("ui", "停止")}
      on_confirm="cancel_run"
      confirm_value={if(@stop_run, do: %{id: @stop_run.id}, else: %{})}
      on_cancel={JS.push("dismiss_cancel_run")}
    >
      {if(@stop_run,
        do:
          dgettext(
            "ui",
            "停止 %{agent} 的这次运行？已排队的直接取消；正在执行的会中断 CLI，已有的改动会保留",
            agent: @stop_run.agent
          )
      )}
    </.confirm_dialog>
    """
  end
end
