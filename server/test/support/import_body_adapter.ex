defmodule HelmsmanWeb.ImportBodyAdapter do
  @moduledoc "Counts request body reads and simulates interrupted uploads without real sockets."
  use Boundary, top_level?: true, check: [in: false, out: false]
  alias Plug.Adapters.Test.Conn, as: TestAdapter

  def read_req_body(state, opts) do
    send(state.owner, {:upload_read, state.upload_ref})

    case state[:upload_chunks] do
      nil -> TestAdapter.read_req_body(state, opts)
      [:error | _] -> {:error, :closed}
      [{status, chunk} | rest] -> {status, chunk, %{state | upload_chunks: rest}}
    end
  end

  defdelegate send_resp(state, status, headers, body), to: TestAdapter
  defdelegate send_file(state, status, headers, path, offset, length), to: TestAdapter
  defdelegate send_chunked(state, status, headers), to: TestAdapter
  defdelegate chunk(state, body), to: TestAdapter
  defdelegate inform(state, status, headers), to: TestAdapter
  defdelegate upgrade(state, protocol, opts), to: TestAdapter
  defdelegate push(state, path, headers), to: TestAdapter
  defdelegate get_peer_data(state), to: TestAdapter
  defdelegate get_sock_data(state), to: TestAdapter
  defdelegate get_ssl_data(state), to: TestAdapter
  defdelegate get_http_protocol(state), to: TestAdapter
end
