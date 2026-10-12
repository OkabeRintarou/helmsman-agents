defmodule HelmsmanProtocol.RepoIdTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Fixtures, RunSpec}

  test "nonempty repo requires a positive integer GitHub repository ID" do
    wire = Fixtures.run_spec()
    missing = put_in(wire["repo"], Map.delete(wire["repo"], "github_repository_id"))

    assert {:error, {:invalid_payload, ["repo", "github_repository_id"], :required}} =
             RunSpec.from_wire(missing)

    for invalid <- [nil, 0, -1, "123456789", 1.5] do
      assert {:error, {:invalid_payload, ["repo", "github_repository_id"], :type}} =
               RunSpec.from_wire(put_in(wire, ["repo", "github_repository_id"], invalid))
    end
  end

  test "repository ID roundtrips and repo can remain absent" do
    assert {:ok, spec} = RunSpec.from_wire(Fixtures.run_spec())
    assert spec.repo.github_repository_id == 123_456_789
    assert {:ok, ^spec} = spec |> RunSpec.to_wire() |> RunSpec.from_wire()
    assert {:ok, %{repo: nil}} = RunSpec.from_wire(Map.put(Fixtures.run_spec(), "repo", nil))
  end
end
