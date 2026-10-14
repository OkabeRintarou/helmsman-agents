defmodule HelmsmanProtocol.RepoRegistrationTest do
  use ExUnit.Case, async: true
  doctest HelmsmanProtocol.RepoField
  alias HelmsmanProtocol.{Fixtures, Messages, Push, Reply, RepoRequestError, Report}

  @vr HelmsmanProtocol.repo_registration_version()
  @messages ~w(repo_browse repo_register repo_remove repo_browse_result repo_change_result)

  defp wire(name), do: Map.merge(Fixtures.reports(), Fixtures.pushes()) |> Map.fetch!(name)

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()

  test "registration is protocol 7, the current version, and the minimum stays 1" do
    assert @vr == 7
    assert HelmsmanProtocol.version() == @vr
    assert HelmsmanProtocol.min_version() == 1
    assert HelmsmanProtocol.compatible?(@vr)
    refute HelmsmanProtocol.compatible?(@vr + 1)
  end

  test "roundtrip: register, a two-item browse result and a change result" do
    for name <- ~w(repo_register repo_browse_result repo_change_result) do
      assert {:ok, value} = Messages.decode(name, wire(name))
      assert {:ok, {^name, encoded}} = Messages.encode(value, @vr)
      assert {:ok, ^value} = Messages.decode(name, json(encoded))
    end

    assert {:ok, %Report.RepoBrowseResult{repositories: [_, _]}} =
             Messages.decode("repo_browse_result", wire("repo_browse_result"))
  end

  test "both results are acknowledged with an empty reply" do
    for name <- ~w(repo_browse_result repo_change_result) do
      assert {:ok, Reply.Empty} = Messages.reply_module(name)
      assert {:ok, %{}} = Messages.encode_reply(name, %Reply.Empty{}, @vr)

      assert {:error, {:not_in_version, 6}} =
               Messages.encode_reply(name, %Reply.Empty{}, @vr - 1)
    end
  end

  test "older versions cannot encode the messages or a reported repo_registration" do
    for name <- @messages, version <- 1..(@vr - 1) do
      {:ok, value} = Messages.decode(name, wire(name))
      assert {:error, {:not_in_version, ^version}} = Messages.encode(value, version)
    end

    {:ok, sync} = Messages.decode("sync", wire("sync"))

    for value <- [true, false] do
      assert {:error, {:not_in_version, 6}} =
               Messages.encode(%{sync | repo_registration: value}, @vr - 1)
    end

    assert {:ok, {"sync", old}} = Messages.encode(%{sync | repo_registration: nil}, @vr - 1)
    refute Map.has_key?(old, "repo_registration")

    assert {:ok, {"sync", new}} = Messages.encode(%{sync | repo_registration: true}, @vr)
    assert new["repo_registration"] == true
  end

  test "a protocol 6 join without repo_registration decodes with nil" do
    join = Map.delete(Fixtures.join(), "repo_registration") |> Map.put("protocol", 6)
    assert {:ok, %Report.Join{repo_registration: nil}} = Messages.decode("join", join)

    assert {:ok, %Report.Join{repo_registration: false}} =
             Messages.decode("join", Map.put(join, "repo_registration", false))

    assert {:error, {:invalid_payload, ["repo_registration"], :type}} =
             Messages.decode("join", Map.put(join, "repo_registration", "yes"))
  end

  test "path escapes are refused at the path field" do
    for path <- ["../secret", "/etc", "app/./x", "app//x", "app/", "a/../b", "app\nx", "app\0x"] do
      assert {:error, {:invalid_payload, ["path"], _}} =
               Messages.decode("repo_register", %{wire("repo_register") | "path" => path}),
             inspect(path)
    end

    for path <- [".", "group/lib", "Ünïcode dir/x"] do
      assert {:ok, %Push.RepoRegister{path: ^path}} =
               Messages.decode("repo_register", %{wire("repo_register") | "path" => path})
    end
  end

  test "path is limited to 16 segments and 1024 bytes" do
    sixteen = Enum.map_join(1..16, "/", &"d#{&1}")

    assert {:ok, _} =
             Messages.decode("repo_register", %{wire("repo_register") | "path" => sixteen})

    for path <- [sixteen <> "/x", String.duplicate("a", 1_025)] do
      assert {:error, {:invalid_payload, ["path"], _}} =
               Messages.decode("repo_register", %{wire("repo_register") | "path" => path})
    end
  end

  test "request IDs are 22 to 64 URL-safe characters" do
    for id <- [String.duplicate("a", 21), "a.aaaaaaaaaaaaaaaaaaaaa", String.duplicate("a", 65)] do
      for name <- @messages do
        assert {:error, {:invalid_payload, ["request_id"], _}} =
                 Messages.decode(name, %{wire(name) | "request_id" => id}),
               "#{name} #{inspect(id)}"
      end
    end

    for id <- [String.duplicate("a", 22), String.duplicate("Z_-9", 16)] do
      assert {:ok, _} = Messages.decode("repo_browse", %{"request_id" => id})
    end
  end

  test "workspaces are 1 to 50 distinct positive integers" do
    for ids <- [[], Enum.to_list(1..51), [7, 7], [0], ["7"]] do
      assert {:error, {:invalid_payload, ["workspaces" | _], _}} =
               Messages.decode("repo_register", %{wire("repo_register") | "workspaces" => ids}),
             inspect(ids)
    end

    assert {:ok, _} =
             Messages.decode("repo_register", %{
               wire("repo_register")
               | "workspaces" => Enum.to_list(1..50)
             })
  end

  test "names follow the local repository name rule" do
    for name <- ["App", "-app", "", String.duplicate("a", 65), "a b"] do
      for message <- ~w(repo_register repo_remove repo_change_result) do
        assert {:error, {:invalid_payload, ["name"], _}} =
                 Messages.decode(message, %{wire(message) | "name" => name}),
               "#{message} #{inspect(name)}"
      end
    end

    candidate = %{"root" => "~/code", "path" => "x", "name" => "x", "registered_as" => "Bad"}

    assert {:error, {:invalid_payload, ["repositories", 0, "registered_as"], _}} =
             Messages.decode("repo_browse_result", %{
               wire("repo_browse_result")
               | "repositories" => [candidate]
             })
  end

  test "roots must not contain NUL and are at most 16" do
    payload = wire("repo_browse_result")

    assert {:error, {:invalid_payload, ["root"], _}} =
             Messages.decode("repo_register", %{wire("repo_register") | "root" => "a\0b"})

    assert {:error, {:invalid_payload, ["roots", 1], _}} =
             Messages.decode("repo_browse_result", %{payload | "roots" => ["~/code", "x\0"]})

    roots = Enum.map(1..17, &"/r#{&1}")

    assert {:error, {:invalid_payload, ["roots"], {:count, 0, 16}}} =
             Messages.decode("repo_browse_result", %{
               payload
               | "roots" => roots,
                 "repositories" => []
             })
  end

  test "a result's repository root must be listed in roots" do
    payload = %{wire("repo_browse_result") | "roots" => ["~/code"]}

    assert {:error, {:invalid_payload, ["repositories", 1, "root"], :not_allowed}} =
             Messages.decode("repo_browse_result", payload)
  end

  test "repositories are at most 200 and empty with an error" do
    payload = wire("repo_browse_result")
    item = %{"root" => "~/code", "path" => "app", "name" => "app", "registered_as" => nil}

    assert {:error, {:invalid_payload, ["repositories"], {:count, 0, 200}}} =
             Messages.decode("repo_browse_result", %{
               payload
               | "repositories" => List.duplicate(item, 201)
             })

    assert {:ok, _} =
             Messages.decode("repo_browse_result", %{
               payload
               | "repositories" => List.duplicate(item, 200)
             })

    assert {:error, {:invalid_payload, ["repositories"], :not_allowed}} =
             Messages.decode("repo_browse_result", %{payload | "error" => "busy"})

    assert {:ok, %Report.RepoBrowseResult{error: :busy, repositories: []}} =
             Messages.decode("repo_browse_result", %{
               payload
               | "error" => "busy",
                 "repositories" => []
             })
  end

  test "error codes are a strict enum and messages are bounded" do
    assert {:error, {:invalid_payload, ["error"], {:enum, _}}} =
             Messages.decode("repo_change_result", %{
               wire("repo_change_result")
               | "error" => "teapot"
             })

    assert {:error, {:invalid_payload, ["action"], {:enum, _}}} =
             Messages.decode("repo_change_result", %{
               wire("repo_change_result")
               | "action" => "edit"
             })

    assert {:error, {:invalid_payload, ["message"], {:too_long, 1_024}}} =
             Messages.decode("repo_change_result", %{
               wire("repo_change_result")
               | "message" => String.duplicate("x", 1_025)
             })

    for code <- RepoRequestError.all() do
      payload = %{wire("repo_change_result") | "error" => Atom.to_string(code)}

      assert {:ok, %Report.RepoChangeResult{error: ^code}} =
               Messages.decode("repo_change_result", payload)
    end

    assert length(RepoRequestError.all()) == 14
  end
end
