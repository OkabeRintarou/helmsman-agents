defmodule HelmsmanProtocolTest do
  use ExUnit.Case, async: true
  doctest HelmsmanProtocol

  test "version/0 returns a positive integer" do
    version = HelmsmanProtocol.version()

    assert is_integer(version)
    assert version > 0
  end
end
