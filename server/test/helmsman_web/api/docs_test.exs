defmodule HelmsmanWeb.API.DocsTest do
  # add-rest-api 5.1: docs/API.md lists exactly the /api/v1 routes.
  use ExUnit.Case, async: true

  alias HelmsmanWeb.API.ImportBodyPlug

  @path Path.expand("../../../../docs/API.md", __DIR__)
  @workspace "/api/v1/w/:slug"

  defp documented do
    for line <- @path |> File.read!() |> String.split("\n"),
        [_, verb, path] <- [
          Regex.run(~r/^\|\s*(GET|POST|PATCH|PUT|DELETE)\s*\|\s*`([^`]+)`/, line)
        ],
        into: MapSet.new() do
      path = if String.starts_with?(path, "/api/"), do: path, else: @workspace <> path
      {verb |> String.downcase() |> String.to_existing_atom(), path}
    end
  end

  defp routed do
    routes =
      for route <- HelmsmanWeb.Router.__routes__(),
          String.starts_with?(route.path, "/api/v1/"),
          into: MapSet.new(),
          do: {route.verb, route.path}

    MapSet.union(routes, MapSet.new(ImportBodyPlug.routes()))
  end

  test "every documented endpoint is routed and every /api/v1 route is documented" do
    documented = documented()
    routed = routed()

    assert MapSet.size(documented) >= 28
    assert MapSet.difference(documented, routed) == MapSet.new(), "documented but not routed"
    assert MapSet.difference(routed, documented) == MapSet.new(), "routed but not documented"
  end
end
