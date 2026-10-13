defmodule HelmsmanDaemon.Launch do
  @moduledoc "Prepared argv, environment, stdin and initial normalized events."
  @type t :: %__MODULE__{
          argv: [String.t()],
          env: [{String.t(), String.t()}],
          drop_env: [String.t()],
          stdin: iodata() | nil,
          close_stdin?: boolean(),
          events: [{atom(), map()}]
        }
  defstruct argv: [], env: [], drop_env: [], stdin: nil, close_stdin?: true, events: []
  use HelmsmanProtocol.Redacted, [:env]
end
