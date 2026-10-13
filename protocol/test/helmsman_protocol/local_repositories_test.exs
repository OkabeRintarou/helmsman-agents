defmodule HelmsmanProtocol.LocalRepositoriesTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Fixtures, LocalRepository, Messages, Reply, Report, RunSpec}

  @v HelmsmanProtocol.local_repositories_version()

  test "version range covers 1 through the local repositories version" do
    current = HelmsmanProtocol.version()
    assert @v <= current
    assert HelmsmanProtocol.min_version() == 1

    assert Enum.map([1, 0, @v, current, current + 1], &HelmsmanProtocol.compatible?/1) ==
             [true, false, true, true, false]
  end

  test "encoding for version 0 fails without a payload" do
    {:ok, status} = Report.RepoStatus.from_wire(Fixtures.repo_status())
    assert {:error, {:not_in_version, 0}} = Messages.encode(status, 0)

    assert {:error, {:not_in_version, 0}} =
             Messages.encode_reply("repo_status", %Reply.Empty{}, 0)
  end

  describe "versions before local repositories" do
    test "a local RunSpec cannot be encoded and a join reply drops local repositories" do
      local = Map.put(Fixtures.run_spec(), "repo", Fixtures.local_repo())
      {:ok, claim} = Reply.Claim.from_wire(%{"runs" => [Fixtures.run_spec(), local]})
      old = @v - 1

      assert {:error, {:not_in_version, ^old}} = Messages.encode_reply("claim", claim, old)
      assert {:ok, %{"runs" => [_, _]}} = Messages.encode_reply("claim", claim, @v)

      {:ok, reply} = Reply.Join.from_wire(Fixtures.join_reply())
      assert reply.local_repositories != []

      for version <- 1..old, name <- ["join", "sync"] do
        assert {:ok, wire} = Messages.encode_reply(name, reply, version)
        refute Map.has_key?(wire, "local_repositories")
        assert {:ok, %Reply.Join{local_repositories: nil}} = Messages.decode_reply(name, wire)
      end

      assert {:ok, %{"local_repositories" => [%{"watch" => [_]}]}} =
               Messages.encode_reply("join", reply, @v)
    end

    test "github repos keep the version 1 wire shape and old payloads decode as github" do
      {:ok, claim} = Reply.Claim.from_wire(%{"runs" => [Fixtures.run_spec()]})
      v1_repo = Map.drop(Fixtures.repo(), ["kind", "name"])

      for version <- 1..(@v - 1) do
        assert {:ok, %{"runs" => [%{"repo" => ^v1_repo}]}} =
                 Messages.encode_reply("claim", claim, version)
      end

      assert {:ok, %RunSpec.Repo{kind: :github, name: nil}} = RunSpec.Repo.from_wire(v1_repo)

      assert {:ok, %RunSpec.Repo{kind: :github}} =
               RunSpec.Repo.new(%{kind: nil, branch: "x"} |> Map.merge(native(v1_repo)))
    end

    test "repo_status and daemon-reported local repositories do not exist" do
      {:ok, status} = Report.RepoStatus.from_wire(Fixtures.repo_status())
      {:ok, join} = Report.Join.from_wire(Fixtures.join())
      old = @v - 1

      assert {:error, {:not_in_version, ^old}} = Messages.encode(status, old)
      assert {:error, {:not_in_version, ^old}} = Messages.encode(join, old)

      assert {:error, {:not_in_version, ^old}} =
               Messages.encode_reply("repo_status", %Reply.Empty{}, old)

      assert {:ok, {"join", wire}} = Messages.encode(%{join | local_repositories: nil}, old)
      refute Map.has_key?(wire, "local_repositories")
      assert {:ok, %Report.Join{local_repositories: nil}} = Messages.decode("join", wire)
    end
  end

  test "repo_status merge results are a strict enum and bounded" do
    payload = put_in(Fixtures.repo_status(), ["results", Access.at(0), "merged"], "maybe")

    assert {:error, {:invalid_payload, ["results", 0, "merged"], {:enum, [:yes, :no, :unknown]}}} =
             Messages.decode("repo_status", payload)

    for merged <- ~w(yes no unknown) do
      payload = put_in(Fixtures.repo_status(), ["results", Access.at(0), "merged"], merged)

      assert {:ok, %Report.RepoStatus{results: [result]}} =
               Messages.decode("repo_status", payload)

      assert Atom.to_string(result.merged) == merged
    end

    result = hd(Fixtures.repo_status()["results"])

    assert {:error, {:invalid_payload, ["results"], {:count, 0, 500}}} =
             Messages.decode(
               "repo_status",
               Map.put(Fixtures.repo_status(), "results", List.duplicate(result, 501))
             )

    assert {:ok, _} =
             Messages.decode(
               "repo_status",
               Map.put(Fixtures.repo_status(), "results", List.duplicate(result, 500))
             )

    assert {:ok, %Reply.Empty{}} = Messages.decode_reply("repo_status", %{})
  end

  test "join reply watch lists hold at most 500 branches" do
    entry = Fixtures.reply_local_repository()

    assert {:error, {:invalid_payload, ["local_repositories", 0, "watch"], {:count, 0, 500}}} =
             Messages.decode_reply(
               "join",
               Map.put(Fixtures.join_reply(), "local_repositories", [
                 Map.put(entry, "watch", List.duplicate(Fixtures.watch(), 501))
               ])
             )

    assert {:ok, _} =
             Messages.decode_reply(
               "sync",
               Map.put(Fixtures.join_reply(), "local_repositories", [
                 Map.put(entry, "watch", List.duplicate(Fixtures.watch(), 500))
               ])
             )
  end

  describe "RunSpec repo kinds" do
    test "local repositories carry no token or address" do
      spec = Map.put(Fixtures.run_spec(), "repo", Fixtures.local_repo())
      assert {:ok, %RunSpec{repo: repo} = decoded} = RunSpec.from_wire(spec)
      assert %RunSpec.Repo{kind: :local, name: "app", branch: "hm/1/t-1"} = repo
      assert repo.git_token == nil and repo.clone_url == nil
      assert RunSpec.to_wire(decoded) == spec

      for field <- ~w(git_token clone_url github_repository_id git_token_expires_at) do
        value = if field == "github_repository_id", do: 9, else: "x"
        path = ["repo", field]

        assert {:error, {:invalid_payload, ^path, :not_allowed}} =
                 RunSpec.from_wire(put_in(spec, path, value))
      end

      for field <- ~w(name base_branch branch rescue_branches) do
        assert {:error, {:invalid_payload, ["repo", ^field], _}} =
                 RunSpec.from_wire(update_in(spec, ["repo"], &Map.delete(&1, field)))
      end

      assert {:error, {:invalid_payload, ["repo", "kind"], {:enum, [:github, :local]}}} =
               RunSpec.from_wire(put_in(spec, ["repo", "kind"], "svn"))
    end

    test "github repositories, typed or untyped, require the push token" do
      untyped = update_in(Fixtures.run_spec(), ["repo"], &Map.drop(&1, ["kind", "name"]))

      for spec <- [Fixtures.run_spec(), untyped] do
        assert {:error, {:invalid_payload, ["repo", "git_token"], :type}} =
                 RunSpec.from_wire(put_in(spec, ["repo", "git_token"], nil))

        assert {:error, {:invalid_payload, ["repo", "git_token"], :required}} =
                 RunSpec.from_wire(update_in(spec, ["repo"], &Map.delete(&1, "git_token")))
      end

      assert {:error, {:invalid_payload, ["git_token"], :type}} =
               RunSpec.Repo.new(native(Fixtures.repo()) |> Map.put(:git_token, nil))

      assert {:ok, %RunSpec.Repo{kind: :local}} =
               RunSpec.Repo.new(
                 kind: :local,
                 name: "app",
                 base_branch: "main",
                 branch: "hm/1/t-1",
                 rescue_branches: []
               )
    end
  end

  test "local repository availability and reason are exclusive" do
    base = Fixtures.local_repository()

    assert {:error, {:invalid_payload, ["unavailable_reason"], :not_allowed}} =
             LocalRepository.from_wire(Map.put(base, "unavailable_reason", "x"))

    assert {:error, {:invalid_payload, ["unavailable_reason"], :required}} =
             LocalRepository.from_wire(Map.put(base, "available", false))

    assert {:ok, %LocalRepository{available: false, default_branch: nil}} =
             LocalRepository.from_wire(
               Map.merge(base, %{
                 "available" => false,
                 "unavailable_reason" => "not a git repository",
                 "default_branch" => nil
               })
             )

    assert {:error, {:invalid_payload, ["local_repositories", 0, "workspaces", 0], :type}} =
             Messages.decode("sync", %{
               "machine" => Fixtures.machine(),
               "clis" => [],
               "max_concurrency" => 1,
               "local_repositories" => [Map.put(base, "workspaces", ["acme"])]
             })
  end

  defp native(wire) do
    {:ok, repo} = RunSpec.Repo.from_wire(wire)
    Map.from_struct(repo)
  end
end
