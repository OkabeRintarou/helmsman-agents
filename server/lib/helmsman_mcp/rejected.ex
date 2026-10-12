defmodule HelmsmanMCP.Rejected do
  @moduledoc """
  A write tool's business refusal that must still commit (decision 16):
  the tool returns `{:ok, %Rejected{reason: reason}}` so that
  `Helmsman.Actors.with_writer/3` commits what was written (a system
  comment, the session's new agent), and `HelmsmanMCP.Pipeline` then
  answers with the error text of `reason` (`isError`). A real failure
  returns `{:error, reason}` instead and rolls everything back.
  """

  @type t :: %__MODULE__{reason: term()}

  @enforce_keys [:reason]
  defstruct [:reason]
end
