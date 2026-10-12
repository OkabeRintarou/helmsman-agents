defmodule HelmsmanWeb.DaemonChannel do
  @moduledoc "Daemon control messages and authorization-aware disconnects."
  use HelmsmanWeb, :channel
  alias Helmsman.{Daemons, Repo}
  alias HelmsmanProtocol.{ErrorReply, Messages, Push, Reply}

  @impl true
  def join("daemon:" <> id, payload, socket) do
    with true <- id == to_string(socket.assigns.daemon_id),
         {:ok, report} <- decode_join(payload),
         true <- HelmsmanProtocol.compatible?(report.protocol),
         {:ok, runtimes} <-
           Daemons.register(socket.assigns.daemon_id, socket.assigns.auth_epoch, report) do
      socket = assign(socket, :protocol, report.protocol)

      {:ok,
       wire_reply(
         "join",
         %Reply.Join{
           daemon_id: socket.assigns.daemon_id,
           runtimes: runtimes,
           terminate_run_ids: []
         },
         socket
       ), socket}
    else
      false ->
        if id == to_string(socket.assigns.daemon_id),
          do: {:error, unsupported()},
          else: {:error, error(:not_found)}

      {:error, :busy} ->
        {:error, error(:wrong_state)}

      {:error, reason} when reason in [:revoked, :reauthorized, :not_found] ->
        disconnect(socket)
        {:error, error(:not_found)}

      _ ->
        {:error, error(:invalid_payload)}
    end
  end

  defp decode_join(%{"protocol" => protocol} = payload) when is_integer(protocol) do
    with {:ok, report} <-
           Messages.decode("join", Map.put(payload, "protocol", HelmsmanProtocol.version())) do
      {:ok, %{report | protocol: protocol}}
    end
  end

  defp decode_join(payload), do: Messages.decode("join", payload)

  @impl true
  def handle_in(name, payload, socket) do
    case Messages.decode(name, payload) do
      {:ok, report} -> handle_report(name, report, socket)
      _ -> {:reply, {:error, error(:invalid_payload)}, socket}
    end
  end

  defp handle_report("sync", report, socket) do
    case Daemons.register(socket.assigns.daemon_id, socket.assigns.auth_epoch, report) do
      {:ok, runtimes} ->
        respond(
          "sync",
          %Reply.Join{
            daemon_id: socket.assigns.daemon_id,
            runtimes: runtimes,
            terminate_run_ids: []
          },
          socket
        )

      {:error, :busy} ->
        {:stop, :normal, {:error, error(:wrong_state)}, socket}

      {:error, reason} when reason in [:revoked, :reauthorized, :not_found] ->
        unauthorized_reply(socket)

      _ ->
        {:reply, {:error, error(:invalid_payload)}, socket}
    end
  end

  defp handle_report("rotate_token", _report, socket) do
    case Daemons.rotate_token(socket.assigns.daemon_id, socket.assigns.auth_epoch) do
      {:ok, token} -> respond("rotate_token", %Reply.RotateToken{token: token}, socket)
      _ -> unauthorized_reply(socket)
    end
  end

  defp handle_report("heartbeat", _report, socket) do
    case Daemons.heartbeat(socket.assigns.daemon_id, socket.assigns.auth_epoch) do
      {:ok, _} -> respond("heartbeat", %Reply.Heartbeat{terminate_run_ids: []}, socket)
      _ -> unauthorized_reply(socket)
    end
  end

  defp handle_report("claim", _report, socket) do
    daemon = Repo.get(Daemons.Daemon, socket.assigns.daemon_id)

    case Daemons.authorized(daemon, socket.assigns.auth_epoch) do
      :ok -> respond("claim", %Reply.Claim{runs: []}, socket)
      _ -> unauthorized_reply(socket)
    end
  end

  defp handle_report(_name, _report, socket), do: {:reply, {:error, error(:not_found)}, socket}

  @impl true
  def handle_info({:daemon_config_changed}, socket) do
    push_message(%Push.ConfigChanged{}, socket)
    {:noreply, socket}
  end

  def handle_info({kind}, socket) when kind in [:daemon_revoked, :daemon_reauthorized] do
    case connection_state(socket) do
      :valid -> {:noreply, socket}
      _ -> stop(socket)
    end
  end

  defp unauthorized_reply(socket) do
    if connection_state(socket) == :revoked, do: push_message(%Push.Revoked{}, socket)
    disconnect(socket)
    {:stop, :normal, {:error, error(:not_found)}, socket}
  end

  defp stop(socket) do
    if connection_state(socket) == :revoked, do: push_message(%Push.Revoked{}, socket)
    disconnect(socket)
    {:stop, :normal, socket}
  end

  defp connection_state(socket) do
    case Repo.get(Daemons.Daemon, socket.assigns.daemon_id) do
      nil -> :reauthorized
      %{revoked_at: revoked} when not is_nil(revoked) -> :revoked
      %{auth_epoch: epoch} when epoch != socket.assigns.auth_epoch -> :reauthorized
      _ -> :valid
    end
  end

  defp disconnect(socket),
    do: HelmsmanWeb.Endpoint.broadcast(HelmsmanWeb.DaemonSocket.id(socket), "disconnect", %{})

  defp push_message(message, socket) do
    {:ok, {name, payload}} = Messages.encode(message, socket.assigns.protocol)
    push(socket, name, payload)
  end

  defp respond(name, reply, socket), do: {:reply, {:ok, wire_reply(name, reply, socket)}, socket}

  defp wire_reply(name, reply, socket) do
    {:ok, payload} = Messages.encode_reply(name, reply, socket.assigns.protocol)
    payload
  end

  defp error(reason) do
    {:ok, reply} =
      ErrorReply.new(
        reason,
        if(reason == :wrong_state,
          do: "state changed concurrently, reconnecting",
          else: Atom.to_string(reason)
        )
      )

    ErrorReply.to_wire(reply)
  end

  defp unsupported do
    {:ok, reply} =
      ErrorReply.unsupported_protocol(HelmsmanWeb.DaemonDeviceController.upgrade_url())

    ErrorReply.to_wire(reply)
  end
end
