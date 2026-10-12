defmodule HelmsmanWeb.DaemonSocket do
  use Phoenix.Socket
  alias Helmsman.Daemons
  channel "daemon:*", HelmsmanWeb.DaemonChannel

  @impl true
  def connect(_params, socket, connect_info) do
    token = connect_info |> Map.get(:x_headers, []) |> List.keyfind("x-helmsman-token", 0)

    case token do
      {_, token} ->
        case Daemons.authenticate(token) do
          {:ok, daemon} ->
            {:ok,
             socket
             |> assign(:daemon_id, daemon.id)
             |> assign(:user_id, daemon.user_id)
             |> assign(:auth_epoch, daemon.auth_epoch)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @impl true
  def id(socket), do: "daemon_socket:#{socket.assigns.daemon_id}:#{socket.assigns.auth_epoch}"
end
