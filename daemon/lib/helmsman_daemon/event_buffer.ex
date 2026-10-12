defmodule HelmsmanDaemon.EventBuffer do
  @moduledoc "Ordered unacknowledged event buffer with bounded batches and selective shedding."
  alias HelmsmanProtocol.Event

  defstruct next_seq: 1,
            pending: :queue.new(),
            in_flight?: false,
            last_sent_at: nil,
            dropped: 0,
            overflow_seq: nil

  def new, do: %__MODULE__{}
  def size(buffer), do: :queue.len(buffer.pending)

  def append(buffer, type, data, at \\ DateTime.utc_now()) do
    if size(buffer) > 10_000 and type in [:thinking, :tool_result] do
      shed(buffer, at)
    else
      {:ok, event} = Event.new(%{seq: buffer.next_seq, type: type, data: data, at: at})
      %{buffer | next_seq: buffer.next_seq + 1, pending: :queue.in(event, buffer.pending)}
    end
  end

  defp shed(%{overflow_seq: nil} = buffer, at) do
    next =
      append(
        buffer,
        :status,
        %{
          level: :warning,
          message: "Dropped 1 thinking/tool_result event due to buffer overflow"
        },
        at
      )

    %{next | dropped: 1, overflow_seq: buffer.next_seq}
  end

  defp shed(buffer, _at), do: %{buffer | dropped: buffer.dropped + 1}

  def take_batch(buffer, now \\ System.monotonic_time(:millisecond)) do
    if buffer.in_flight? or (buffer.last_sent_at && now - buffer.last_sent_at < 1_000) do
      {[], buffer}
    else
      batch = buffer.pending |> :queue.to_list() |> Enum.take(200)

      {batch,
       %{
         buffer
         | in_flight?: batch != [],
           last_sent_at: if(batch == [], do: buffer.last_sent_at, else: now)
       }}
    end
  end

  def ack(buffer, seq) do
    pending =
      buffer.pending
      |> :queue.to_list()
      |> Enum.drop_while(&(&1.seq <= seq))
      |> :queue.from_list()

    %{buffer | pending: pending, in_flight?: false}
  end

  def failed(buffer), do: %{buffer | in_flight?: false}
  def discard(buffer), do: %{buffer | pending: :queue.new(), in_flight?: false}
end
