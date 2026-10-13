defmodule HelmsmanWeb.API.ActorsController do
  @moduledoc "`/actors` and `/agents`: `list_actors` and `list_agents` over REST."

  use HelmsmanWeb.API.Controller

  alias HelmsmanMCP.Tools.{ListActors, ListAgents}

  tool_action(:index, ListActors, response: Schemas.ActorList, tag: "identities")
  tool_action(:agents, ListAgents, response: Schemas.AgentList, tag: "identities")
end
