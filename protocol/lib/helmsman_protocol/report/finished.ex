defmodule HelmsmanProtocol.Report.Finished do
  @moduledoc "Report.Finished protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  field(:status, {:enum, ~w(succeeded failed cancelled)a})

  field(:failure_reason, {:enum, HelmsmanProtocol.FailureReason.daemon_reportable()},
    nullable: true
  )

  field(:error, :string, max_bytes: 16_384, nullable: true)
  field(:session_id, :string, nullable: true)
  field(:summary, :string, max_bytes: 4_096, nullable: true)
  embeds(:usage, HelmsmanProtocol.Event.Usage, nullable: true)

  def validate(%{status: :failed, failure_reason: nil}),
    do: HelmsmanProtocol.Schema.invalid(["failure_reason"], :required)

  def validate(%{status: status, failure_reason: reason})
      when status != :failed and not is_nil(reason),
      do: HelmsmanProtocol.Schema.invalid(["failure_reason"], :not_allowed)

  def validate(value), do: {:ok, value}
end
