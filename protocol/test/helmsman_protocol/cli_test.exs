defmodule HelmsmanProtocol.CLITest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{CLI, Fixtures, Report}

  test "vendor roundtrips in join and legacy sync keeps null" do
    payload = put_in(Fixtures.join(), ["clis", Access.at(0), "vendor"], "zai")
    assert {:ok, join} = Report.Join.from_wire(payload)
    assert [%{vendor: "zai"}] = join.clis
    wire = join |> Report.Join.to_wire() |> JSON.encode!() |> JSON.decode!()
    assert Report.Join.from_wire(wire) == {:ok, join}

    assert {:ok, sync} =
             Report.Sync.from_wire(
               Map.update!(
                 Fixtures.join(),
                 "clis",
                 &Enum.map(&1, fn cli -> Map.delete(cli, "vendor") end)
               )
             )

    assert [%{vendor: nil}] = sync.clis
    assert HelmsmanProtocol.version() == 6
  end

  test "vendor is nullable and validates format rather than known keys" do
    for vendor <- [nil, "newco", String.duplicate("a", 32)] do
      attrs = Map.put(Fixtures.cli(), "vendor", vendor)
      assert {:ok, cli} = CLI.from_wire(attrs)
      assert cli.vendor == vendor
      assert CLI.new(Map.from_struct(cli)) == {:ok, cli}
    end

    assert {:ok, %{vendor: nil}} = CLI.from_wire(Map.delete(Fixtures.cli(), "vendor"))
    assert {:ok, cli} = CLI.from_wire(Fixtures.cli())
    assert {:ok, %{vendor: nil}} = CLI.new(Map.delete(Map.from_struct(cli), :vendor))
  end

  test "invalid vendor returns accurate paths through both decoders and join" do
    for vendor <- [
          "https://api.z.ai",
          "",
          "Zai",
          "z-ai",
          "z.ai",
          "z/ai",
          String.duplicate("a", 33)
        ] do
      attrs = Map.put(Fixtures.cli(), "vendor", vendor)
      assert {:error, {:invalid_payload, ["vendor"], _}} = CLI.from_wire(attrs)
      assert {:ok, cli} = CLI.from_wire(Fixtures.cli())

      assert {:error, {:invalid_payload, ["vendor"], _}} =
               CLI.new(Map.put(Map.from_struct(cli), :vendor, vendor))

      payload = Map.put(Fixtures.join(), "clis", [attrs])

      assert {:error, {:invalid_payload, ["clis", 0, "vendor"], _}} =
               Report.Join.from_wire(payload)
    end
  end
end
