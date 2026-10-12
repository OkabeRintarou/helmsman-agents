defmodule HelmsmanProtocol.RunSpec do
  @moduledoc "RunSpec protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  embeds(:workspace, HelmsmanProtocol.RunSpec.Workspace)
  embeds(:task, HelmsmanProtocol.RunSpec.Task, nullable: true)
  embeds(:agent, HelmsmanProtocol.RunSpec.Agent)
  field(:prompt, :string)
  field(:resume_session_id, :string, nullable: true)
  embeds(:repo, HelmsmanProtocol.RunSpec.Repo, nullable: true)
  embeds(:mcp, HelmsmanProtocol.RunSpec.MCP)
  embeds(:limits, HelmsmanProtocol.RunSpec.Limits)
  embeds(:trigger, HelmsmanProtocol.RunSpec.Trigger)

  use HelmsmanProtocol.Redacted, [
    {:nested, :agent, [:env, :extra_mcp_servers]},
    {:nested, :repo, [:git_token]},
    {:nested, :mcp, [:token]}
  ]
end
