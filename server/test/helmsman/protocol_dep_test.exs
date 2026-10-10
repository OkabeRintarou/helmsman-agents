defmodule Helmsman.ProtocolDepTest do
  use ExUnit.Case, async: true

  test "the shared protocol library is available with a positive version" do
    version = HelmsmanProtocol.version()

    assert is_integer(version)
    assert version > 0
  end
end
