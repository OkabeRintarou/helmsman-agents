defmodule HelmsmanProtocol.ReadmeTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Event, FailureReason, Messages}

  test "README includes every message, event type and failure code" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))

    values =
      Messages.daemon_to_server() ++
        Messages.server_to_daemon() ++
        Enum.map(Event.types() ++ FailureReason.all(), &Atom.to_string/1)

    for value <- values, do: assert(readme =~ value, "README missing #{value}")
  end
end
