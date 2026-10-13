defmodule HelmsmanDaemon.Launch do
  @moduledoc """
  Prepared argv, environment, stdin and initial normalized events.

  `drop_env` names inherited variables to remove before `env` is applied.
  `track_descendants` asks the worker to follow the CLI's descendants that
  leave its process group (`add-cursor-adapter` decision 10; Linux only).
  """
  @type t :: %__MODULE__{
          argv: [String.t()],
          env: [{String.t(), String.t()}],
          drop_env: [String.t()],
          stdin: iodata() | nil,
          close_stdin?: boolean(),
          track_descendants: boolean(),
          events: [{atom(), map()}]
        }
  defstruct argv: [],
            env: [],
            drop_env: [],
            stdin: nil,
            close_stdin?: true,
            track_descendants: false,
            events: []

  use HelmsmanProtocol.Redacted, [:env]
end
