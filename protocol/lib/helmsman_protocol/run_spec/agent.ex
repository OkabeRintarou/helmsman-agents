defmodule HelmsmanProtocol.RunSpec.Agent do
  @moduledoc "RunSpec.Agent protocol payload."
  use HelmsmanProtocol.Schema
  field(:name, :string)
  field(:provider, {:enum, HelmsmanProtocol.providers()})
  field(:model, :string, nullable: true, min_bytes: 1, max_bytes: 128)
  field(:effort, :string, nullable: true, min_bytes: 1, max_bytes: 128)
  list(:custom_args, :string, max: 64, item_min_bytes: 1, item_max_bytes: 4_096)
  field(:env, :string_map)
  field(:extra_mcp_servers, :json_object)
  embeds(:provider_account, HelmsmanProtocol.ProviderAccount, nullable: true)

  use HelmsmanProtocol.Redacted, [
    :env,
    :extra_mcp_servers,
    {:nested, :provider_account, [:api_key, {:nested, :headers, [:value]}]}
  ]
end
