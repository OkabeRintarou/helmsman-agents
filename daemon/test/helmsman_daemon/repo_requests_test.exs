defmodule HelmsmanDaemon.RepoRequestsTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureLog
  import HelmsmanDaemon.WebRepoHelpers
  import HelmsmanDaemon.LocalRepoHelpers, only: [served: 1]
  alias HelmsmanDaemon.RepoRequests
  alias HelmsmanProtocol.Push

  setup do
    home = web_home()
    code = dir!(Path.join(home, "code"))
    repo!(Path.join(code, "app"))
    allow!(["~/code"])
    served([{7, "acme"}])
    %{code: code}
  end

  # A browse that blocks on its first directory until the test sends :go
  # (or sets the flag); later browses run through.
  defp blocking(flag \\ :atomics.new(1, [])) do
    test = self()

    fn ->
      if :atomics.get(flag, 1) == 0 do
        send(test, {:blocked, self()})
        receive do: (:go -> :atomics.put(flag, 1, 1))
      end
    end
  end

  defp start(opts \\ []) do
    test = self()
    start_supervised!({Task.Supervisor, name: HelmsmanDaemon.RepoTaskSupervisor})

    start_supervised!(
      {RepoRequests,
       Keyword.merge(
         [deliver: fn report, sync? -> send(test, {:result, report, sync?}) end],
         opts
       )}
    )
  end

  defp browse_push, do: %Push.RepoBrowse{request_id: request_id()}

  test "a request arriving while another runs is answered busy" do
    start(browse_on_visit: blocking())
    browse = browse_push()
    RepoRequests.submit(browse)
    assert_receive {:blocked, task}, 5_000

    register = register_push([])
    RepoRequests.submit(register)

    assert_receive {:result, %Report.RepoChangeResult{error: :busy, action: :register} = busy,
                    false}

    assert busy.request_id == register.request_id

    other_browse = browse_push()
    RepoRequests.submit(other_browse)

    assert_receive {:result,
                    %Report.RepoBrowseResult{error: :busy, repositories: [], roots: []} = busy,
                    false}

    assert busy.request_id == other_browse.request_id

    send(task, :go)
    assert_receive {:result, %Report.RepoBrowseResult{error: nil} = result, false}, 5_000
    assert result.request_id == browse.request_id
    assert [%{path: "app"}] = result.repositories
    refute Map.has_key?(decoded(), "local_repositories")
  end

  test "a repeated request ID is ignored, without a reply" do
    start()
    push = register_push([])
    RepoRequests.submit(push)
    assert_receive {:result, %Report.RepoChangeResult{error: nil}, true}, 5_000
    RepoRequests.submit(push)
    RepoRequests.submit(%Push.RepoRemove{request_id: push.request_id, name: "app"})
    refute_receive {:result, _, _}, 200
    assert [%{"name" => "app"}] = configured()
  end

  test "only the last 64 request IDs are remembered" do
    start()
    first = %Push.RepoRemove{request_id: request_id(), name: "ghost"}
    RepoRequests.submit(first)
    assert_receive {:result, %Report.RepoChangeResult{error: :not_configured}, false}, 5_000

    for _ <- 1..64 do
      RepoRequests.submit(%Push.RepoRemove{request_id: request_id(), name: "ghost"})
      assert_receive {:result, _, false}, 5_000
    end

    RepoRequests.submit(first)
    assert_receive {:result, %Report.RepoChangeResult{error: :not_configured}, false}, 5_000
  end

  test "a task running past the limit is killed and answered busy" do
    flag = :atomics.new(1, [])
    start(browse_on_visit: blocking(flag), request_timeout_ms: 100)
    push = browse_push()

    log =
      capture_log(fn ->
        RepoRequests.submit(push)
        assert_receive {:blocked, task}, 5_000
        ref = Process.monitor(task)

        assert_receive {:result,
                        %Report.RepoBrowseResult{
                          error: :busy,
                          message: "request timed out on the machine"
                        }, false},
                       2_000

        assert_receive {:DOWN, ^ref, :process, ^task, :killed}
      end)

    assert log =~ push.request_id

    :atomics.put(flag, 1, 1)
    RepoRequests.submit(browse_push())
    assert_receive {:result, %Report.RepoBrowseResult{error: nil}, false}, 5_000
  end

  test "successful changes ask for a sync, failures do not; messages are bounded" do
    start()
    RepoRequests.submit(register_push(name: "Bad"))
    assert_receive {:result, %Report.RepoChangeResult{error: :invalid_name}, false}, 5_000

    RepoRequests.submit(register_push([]))
    assert_receive {:result, %Report.RepoChangeResult{error: nil, action: :register}, true}, 5_000

    RepoRequests.submit(%Push.RepoRemove{request_id: request_id(), name: "app"})
    assert_receive {:result, %Report.RepoChangeResult{error: nil, action: :remove}, true}, 5_000

    allow!([])
    RepoRequests.submit(browse_push())
    assert_receive {:result, %Report.RepoBrowseResult{error: :disabled, roots: []}, false}, 5_000
  end

  test "a browse whose budget runs out before the roots are known answers busy" do
    start(browse_time_limit_ms: 50, browse_on_start: fn -> Process.sleep(:infinity) end)
    RepoRequests.submit(browse_push())

    assert_receive {:result,
                    %Report.RepoBrowseResult{
                      error: :busy,
                      message: "listing timed out on the machine"
                    }, false},
                   2_000
  end

  test "every report it produces encodes for protocol 7" do
    start()

    for push <- [
          browse_push(),
          register_push(path: "missing"),
          register_push([]),
          remove_push("app")
        ] do
      RepoRequests.submit(push)
      assert_receive {:result, report, _}, 5_000
      assert {:ok, _} = HelmsmanProtocol.Messages.encode(report, 7)
    end
  end
end
