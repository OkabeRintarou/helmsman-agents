defmodule HelmsmanProtocol.RunSpecSnapshotTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Fixtures, Messages, Reply, RunSpec}

  @v HelmsmanProtocol.snapshot_version()

  defp snapshot_repo(base \\ Fixtures.repo()) do
    Map.merge(base, %{"mode" => "snapshot", "branch" => nil, "rescue_branches" => []})
  end

  defp spec_with(repo), do: Map.put(Fixtures.run_spec(), "repo", repo)

  defp claim(repo) do
    {:ok, claim} = Reply.Claim.from_wire(%{"runs" => [spec_with(repo)]})
    claim
  end

  test "the snapshot version is the current version" do
    assert @v == 6
    assert HelmsmanProtocol.version() == @v
  end

  describe "read-only checkout roundtrip" do
    test "a github snapshot encodes for version 6 and decodes to the same structure" do
      {:ok, spec} = RunSpec.from_wire(spec_with(snapshot_repo()))

      assert %RunSpec.Repo{
               kind: :github,
               mode: :snapshot,
               base_branch: "main",
               branch: nil,
               rescue_branches: []
             } = spec.repo

      assert {:ok, %{"runs" => [wire]}} =
               Messages.encode_reply("claim", %Reply.Claim{runs: [spec]}, @v)

      assert %{"mode" => "snapshot", "branch" => nil, "rescue_branches" => []} = wire["repo"]
      assert {:ok, ^spec} = RunSpec.from_wire(wire)
    end

    test "a native snapshot repository roundtrips through new/1 and to_wire/1" do
      {:ok, native} = RunSpec.Repo.from_wire(snapshot_repo())

      assert {:ok, repo} =
               RunSpec.Repo.new(%{Map.from_struct(native) | branch: nil, rescue_branches: []})

      assert repo == native
      assert {:ok, ^repo} = RunSpec.Repo.from_wire(RunSpec.Repo.to_wire(repo))
    end

    test "a local snapshot carries only the name" do
      repo = snapshot_repo(Fixtures.local_repo())

      assert {:ok, %RunSpec.Repo{kind: :local, mode: :snapshot, name: "app"}} =
               RunSpec.Repo.from_wire(repo)

      assert {:ok, %{"runs" => [%{"repo" => ^repo}]}} =
               Messages.encode_reply("claim", claim(repo), @v)
    end
  end

  describe "snapshot field rules" do
    test "a task branch on a snapshot points at repo.branch" do
      repo = %{snapshot_repo() | "branch" => "hm/7/bos-1"}

      assert {:error, {:invalid_payload, ["repo", "branch"], :not_allowed}} =
               RunSpec.from_wire(spec_with(repo))

      assert {:error, {:invalid_payload, ["runs", 0, "repo", "branch"], :not_allowed}} =
               Reply.Claim.from_wire(%{"runs" => [spec_with(repo)]})
    end

    test "rescue branches on a snapshot are rejected" do
      repo = %{snapshot_repo() | "rescue_branches" => ["hm/7/bos-1-run-3"]}

      assert {:error, {:invalid_payload, ["repo", "rescue_branches"], :not_allowed}} =
               RunSpec.from_wire(spec_with(repo))
    end

    test "a missing branch on a snapshot is accepted" do
      repo = Map.delete(snapshot_repo(), "branch")
      assert {:ok, %RunSpec.Repo{mode: :snapshot, branch: nil}} = RunSpec.Repo.from_wire(repo)
    end

    test "an unknown mode is rejected" do
      assert {:error, {:invalid_payload, ["mode"], {:enum, [:task, :snapshot]}}} =
               RunSpec.Repo.from_wire(%{Fixtures.repo() | "mode" => "readonly"})
    end
  end

  describe "task mode is the default" do
    test "a version 5 repository without mode decodes as task and still needs a branch" do
      v5 = Map.delete(Fixtures.repo(), "mode")
      assert {:ok, %RunSpec.Repo{mode: :task, branch: "hm/T-1"}} = RunSpec.Repo.from_wire(v5)

      assert {:error, {:invalid_payload, ["branch"], :required}} =
               RunSpec.Repo.from_wire(Map.delete(v5, "branch"))

      assert {:error, {:invalid_payload, ["repo", "branch"], :required}} =
               RunSpec.from_wire(spec_with(%{v5 | "branch" => nil}))

      assert {:error, {:invalid_payload, ["branch"], :required}} =
               RunSpec.Repo.from_wire(%{Fixtures.repo() | "branch" => nil})
    end

    test "native nil mode becomes task" do
      {:ok, repo} = RunSpec.Repo.from_wire(Fixtures.repo())

      assert {:ok, %RunSpec.Repo{mode: :task}} =
               RunSpec.Repo.new(%{Map.from_struct(repo) | mode: nil})
    end
  end

  describe "encoding for older versions" do
    test "a snapshot cannot be encoded below version 6; a task repository drops mode" do
      for version <- 1..(@v - 1) do
        assert {:error, {:not_in_version, ^version}} =
                 Messages.encode_reply("claim", claim(snapshot_repo()), version)

        assert {:error, {:not_in_version, ^version}} =
                 Messages.encode_reply(
                   "claim",
                   claim(snapshot_repo(Fixtures.local_repo())),
                   version
                 )

        assert {:ok, %{"runs" => [%{"repo" => repo}]}} =
                 Messages.encode_reply("claim", claim(Fixtures.repo()), version)

        refute Map.has_key?(repo, "mode")
        assert repo["branch"] == "hm/T-1"
      end
    end

    test "version 6 keeps mode for task repositories and runs without a repository" do
      assert {:ok, %{"runs" => [%{"repo" => %{"mode" => "task"}}]}} =
               Messages.encode_reply("claim", claim(Fixtures.repo()), @v)

      for version <- 1..@v do
        assert {:ok, %{"runs" => [%{"repo" => nil}]}} =
                 Messages.encode_reply("claim", claim(nil), version)
      end
    end
  end
end
