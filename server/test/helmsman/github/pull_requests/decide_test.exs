defmodule Helmsman.GitHub.PullRequests.DecideTest do
  # add-pr-reconcile-merge 1.3: the decision table (decisions 6, 7, 8, 9,
  # 21, 22; designs/15 §7); add-squads 3.2: the assignee side. Pure: no
  # database.
  use ExUnit.Case, async: true

  alias Helmsman.GitHub.PullRequest
  alias Helmsman.GitHub.PullRequests.Decide

  @now ~U[2026-10-13 12:00:00.000000Z]
  @dev 10
  @review 11
  @alice 20
  @system 30

  defp sha(c), do: String.duplicate(c, 40)

  defp push(id, head, base, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        agent_id: @dev,
        causal_agent_ids: [@dev],
        head_sha: head,
        base_sha: base,
        rescue_branch: nil,
        claimed_at: DateTime.add(@now, id - 1000)
      },
      extra
    )
  end

  defp snap(extra \\ %{}) do
    p = push(1, sha("c"), sha("0"))

    base = %{
      task: %{
        id: 1,
        ident: "BOS-12",
        title: "Fix login",
        body: "Body",
        status: :verified,
        assignee_id: @dev,
        slug: "acme",
        creator_name: "alice"
      },
      project: %{
        base_branch: "main",
        merge_policy: "on_verified",
        merge_method: "squash",
        require_ci: true,
        delete_branch_after_merge: true
      },
      repository: %{id: 1, owner: "acme", name: "app", available?: true},
      branch: "hm/7/bos-12",
      pr: row(),
      pushes: [p],
      latest_push: p,
      active_run_id: nil,
      verification: verification(),
      max_auto_reopens: 3,
      public_url: "https://hm.example"
    }

    deep_merge(base, extra)
  end

  defp deep_merge(base, extra) do
    Map.merge(base, Map.new(extra), fn
      key, %{} = a, %{} = b when key in [:task, :project, :repository, :verification] ->
        Map.merge(a, b)

      _key, _a, b ->
        b
    end)
  end

  defp row(extra \\ %{}) do
    struct!(
      %PullRequest{
        id: 1,
        number: 12,
        url: "https://github.com/acme/app/pull/12",
        branch: "hm/7/bos-12",
        base_branch: "main",
        state: :open,
        head_sha: sha("c"),
        merge_status: :none,
        auto_reopen_count: 0,
        closed_by_helmsman: false,
        draft_supported: true
      },
      extra
    )
  end

  defp verification(extra \\ %{}) do
    Map.merge(
      %{
        id: 100,
        actor_id: @alice,
        actor_kind: :human,
        actor_name: "alice",
        verified_sha: sha("c"),
        run_causal_agent_ids: [],
        inserted_at: DateTime.add(@now, -3600)
      },
      extra
    )
  end

  defp facts(extra \\ %{}) do
    Map.merge(
      %{
        number: 12,
        node_id: "PR_12",
        url: "https://github.com/acme/app/pull/12",
        state: :open,
        head_sha: sha("c"),
        base_branch: "main",
        merge_commit_sha: nil,
        mergeable: true,
        mergeable_state: "clean"
      },
      extra
    )
  end

  defp run_check(name, conclusion, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "status" => if(conclusion, do: "completed", else: "in_progress"),
        "conclusion" => conclusion,
        "details_url" => "https://ci.example/#{name}"
      },
      extra
    )
  end

  defp gh(extra \\ %{}) do
    Map.merge(
      %{
        pr: facts(),
        checks: %{runs: [run_check("test", "success")], statuses: []},
        chain_base: %{sha("0") => "behind"}
      },
      extra
    )
  end

  defp decide(s, g \\ gh()), do: Decide.decide(s, g, @now)

  defp merge?({actions, _changes}), do: Enum.any?(actions, &match?({:merge, _}, &1))

  defp reason({_actions, changes}), do: Keyword.get(changes, :merge_reason)
  defp status({_actions, changes}), do: Keyword.get(changes, :merge_status)

  describe "decision 6: the target state" do
    test "no pull request, a push, in progress: a draft is opened (首次推送)" do
      s = snap(%{pr: nil, task: %{status: :in_progress}})
      assert {[{:create, create}], []} = decide(s, %{})

      assert %{
               head: "hm/7/bos-12",
               base: "main",
               draft: true,
               title: "BOS-12: Fix login",
               head_sha: head
             } = create

      assert head == sha("c")
      assert create.body =~ "Task: https://hm.example/w/acme/t/BOS-12"
      assert create.body =~ "> Body"
      assert create.body =~ "Managed by Helmsman."
    end

    test "done or verified: not a draft" do
      for status <- [:done, :verified] do
        assert {[{:create, %{draft: false}}], []} =
                 decide(snap(%{pr: nil, task: %{status: status}}), %{})
      end
    end

    test "no push, or cancelled / rejected: nothing" do
      assert {[], []} = decide(snap(%{pr: nil, latest_push: nil, pushes: []}), %{})

      for status <- [:cancelled, :rejected],
          do: assert({[], []} = decide(snap(%{pr: nil, task: %{status: status}}), %{}))
    end

    test "the body quotes at most 2000 characters" do
      body = Decide.body(snap(%{task: %{body: String.duplicate("é", 2100)}}))
      assert body =~ "> …"
      assert body |> String.split("\n") |> Enum.at(2) |> String.length() == 2002
    end

    test "an unrecorded open pull request is adopted, then judged" do
      found = facts(%{number: 15, state: :open})
      s = snap(%{pr: row(%{state: :merged, merged_at: @now}), task: %{status: :in_progress}})

      assert {[{:adopt, ^found}, :to_draft], changes} =
               decide(s, gh(%{pr: facts(%{state: :merged}), found: found}))

      assert changes[:state] == :open
    end

    test "a merge not recorded yet is recorded before adopting" do
      s = snap(%{pr: row(%{merged_at: nil}), task: %{status: :in_progress}})
      g = gh(%{pr: facts(%{state: :merged}), found: facts(%{number: 15})})
      {actions, changes} = decide(s, g)
      assert changes[:merged_at] == @now
      refute Enum.any?(actions, &match?({:adopt, _}, &1))
    end

    test "open or draft, cancelled / rejected: closed (撤销)" do
      for status <- [:cancelled, :rejected], state <- [:open, :draft] do
        s = snap(%{task: %{status: status}})
        assert {[:close], _} = decide(s, gh(%{pr: facts(%{state: state})}))
      end
    end

    test "open, new / in progress: to draft; skipped when drafts are unsupported" do
      for status <- [:new, :in_progress] do
        assert {[:to_draft], _} = decide(snap(%{task: %{status: status}}))

        s = snap(%{task: %{status: status}, pr: row(%{draft_supported: false})})
        assert {[], _} = decide(s)
      end
    end

    test "draft, done / verified: ready for review (完成后可评审)" do
      for status <- [:done, :verified] do
        assert {[:ready], _} =
                 decide(snap(%{task: %{status: status}}), gh(%{pr: facts(%{state: :draft})}))
      end
    end

    test "draft, new / in progress and open, done: nothing to do" do
      assert {[], _} =
               decide(snap(%{task: %{status: :new}}), gh(%{pr: facts(%{state: :draft})}))

      assert {[], _} = decide(snap(%{task: %{status: :done}}))
    end

    test "closed by Helmsman: reopened when the task is resumed (撤销与恢复)" do
      s = snap(%{task: %{status: :new}, pr: row(%{closed_by_helmsman: true})})
      assert {[:reopen], _} = decide(s, gh(%{pr: facts(%{state: :closed})}))

      s = snap(%{task: %{status: :cancelled}, pr: row(%{closed_by_helmsman: true})})
      assert {[], _} = decide(s, gh(%{pr: facts(%{state: :closed})}))
    end

    test "closed on GitHub by someone else: recorded; blocked when verified (被人在 GitHub 上关闭)" do
      result = decide(snap(), gh(%{pr: facts(%{state: :closed})}))
      assert {[], changes} = result
      assert changes[:state] == :closed
      assert status(result) == :blocked and reason(result) == :pr_closed
      assert changes[:merge_note] =~ "reopen it there"

      result = decide(snap(%{task: %{status: :in_progress}}), gh(%{pr: facts(%{state: :closed})}))
      assert {[], changes} = result
      assert changes[:state] == :closed
      refute Keyword.has_key?(changes, :merge_reason)
    end

    test "merged, first seen: recorded, the merge hook, the cleanup" do
      g = gh(%{pr: facts(%{state: :merged, merge_commit_sha: sha("m")})})
      assert {actions, changes} = decide(snap(), g)
      assert actions == [:cleanup]
      assert changes[:state] == :merged
      assert changes[:merge_status] == :merged
      assert changes[:merged_sha] == sha("m")
      assert changes[:merged_at] == @now
      assert changes[:included_sha] == sha("c")
    end

    test "merged by a person while in progress: recorded, no cleanup, task unchanged" do
      s = snap(%{task: %{status: :in_progress}})
      assert {[], changes} = decide(s, gh(%{pr: facts(%{state: :merged})}))
      assert changes[:merge_status] == :merged
    end

    test "merged, reopened and pushed again: a new pull request (合并后重开再推送)" do
      p2 = push(2, sha("d"), sha("c"))

      s =
        snap(%{
          task: %{status: :in_progress},
          pr: row(%{state: :merged, merged_at: @now, included_sha: sha("c")}),
          pushes: [push(1, sha("c"), sha("0")), p2],
          latest_push: p2
        })

      assert {[{:create, %{head_sha: head, draft: true}}], _} =
               decide(s, gh(%{pr: facts(%{state: :merged}), included: false}))

      assert head == sha("d")
    end
  end

  describe "decision 21: what the merged pull request includes" do
    defp merged_snap(latest, included_sha, head \\ sha("c")) do
      p = push(2, latest, sha("0"))

      snap(%{
        task: %{status: :done},
        pr: row(%{state: :merged, merged_at: @now, head_sha: head, included_sha: included_sha}),
        pushes: [p],
        latest_push: p
      })
    end

    test "the latest push is the merged head: included without asking GitHub" do
      s = merged_snap(sha("c"), nil)
      assert {[], changes} = decide(s, gh(%{pr: facts(%{state: :merged})}))
      assert changes[:included_sha] == sha("c")
    end

    test "the merged head is ahead (a person added commits): included, no new pull request" do
      s = merged_snap(sha("1"), nil, sha("2"))
      g = gh(%{pr: facts(%{state: :merged, head_sha: sha("2")}), included: true})
      assert {[], changes} = decide(s, g)
      assert changes[:included_sha] == sha("1")
    end

    test "behind / diverged / 404: not included, a new pull request (合并前领取、合并后才推送)" do
      s = merged_snap(sha("3"), sha("1"), sha("1"))
      g = gh(%{pr: facts(%{state: :merged, head_sha: sha("1")}), included: false})
      assert {[{:create, %{head_sha: head}}], changes} = decide(s, g)
      assert head == sha("3")
      refute Keyword.has_key?(changes, :included_sha)
    end

    test "unknown (the compare failed): nothing" do
      s = merged_snap(sha("3"), sha("1"), sha("1"))
      g = gh(%{pr: facts(%{state: :merged, head_sha: sha("1")})})
      assert {[], changes} = decide(s, g)
      refute Keyword.has_key?(changes, :included_sha)
    end

    test "already recorded: nothing more" do
      s = merged_snap(sha("c"), sha("c"))
      s = put_in(s.task.status, :in_progress)
      assert {[], _} = decide(s, gh(%{pr: facts(%{state: :merged})}))
    end
  end

  describe "decision 7: merge preconditions" do
    test "all met: merge at the verified commit (独立的人验收后合并)" do
      assert {[{:merge, %{sha: sha, method: "squash"}}], changes} = decide(snap())
      assert sha == sha("c")
      assert changes[:checks_state] == :success
      assert changes[:waiting_since] == nil
    end

    test "1. manual: none without a merge request; a request for V lets it through" do
      s = snap(%{project: %{merge_policy: "manual"}})
      result = decide(s)
      assert status(result) == :none and reason(result) == :policy_manual
      refute merge?(result)

      request = %{"verification_event_id" => 100, "by_actor_id" => @alice}
      assert merge?(decide(put_in(s.pr.merge_request, request)))

      # A request for an earlier verification does not count.
      old = %{"verification_event_id" => 99, "by_actor_id" => @alice}
      assert reason(decide(put_in(s.pr.merge_request, old))) == :policy_manual
    end

    test "1. on_verified_human: an agent's verification is blocked (只有 Agent 验收)" do
      s =
        snap(%{
          project: %{merge_policy: "on_verified_human"},
          verification: %{actor_id: @review, actor_kind: :agent, actor_name: "keel/review"}
        })

      result = decide(s)
      assert status(result) == :blocked and reason(result) == :agent_verified
      assert merge?(decide(snap(%{project: %{merge_policy: "on_verified_human"}})))

      request = %{"verification_event_id" => 100}
      assert merge?(decide(put_in(s.pr.merge_request, request)))
    end

    test "2. the verifier pushed commits" do
      s = snap(%{verification: %{actor_id: @dev, actor_kind: :agent, actor_name: "keel/dev"}})
      result = decide(s)
      assert reason(result) == :not_independent and status(result) == :blocked
      assert elem(result, 1)[:merge_note] =~ "keel/dev contributed commits"
    end

    test "2. an agent verifier whose run's causal chain meets the provenance (开发 Agent 自己 @ 来的评审 Agent)" do
      s =
        snap(%{
          verification: %{
            actor_id: @review,
            actor_kind: :agent,
            actor_name: "keel/review",
            run_causal_agent_ids: [@dev, @review]
          }
        })

      result = decide(s)
      assert reason(result) == :not_independent
      assert elem(result, 1)[:merge_note] =~ "caused by an agent"

      # An independent review agent.
      s = put_in(s.verification.run_causal_agent_ids, [@review])
      assert merge?(decide(s))
    end

    test "2. the provenance includes rescue-branch pushes and causal chains" do
      rescued =
        push(2, sha("r"), sha("c"), %{
          agent_id: 40,
          causal_agent_ids: [40, @alice],
          rescue_branch: "x"
        })

      s = snap(%{pushes: [push(1, sha("c"), sha("0")), rescued]})
      assert reason(decide(s)) == :not_independent
    end

    test "2. self-verification by the assignee and the system identity" do
      s = snap(%{task: %{assignee_id: @alice}})
      assert elem(decide(s), 1)[:merge_note] =~ "self-verification"

      s = snap(%{verification: %{actor_id: @system, actor_kind: :system, actor_name: "system"}})
      assert elem(decide(s), 1)[:merge_note] =~ "system identity"
    end

    test "2. an owner's skip reason skips independence; a plain request does not" do
      s = snap(%{verification: %{actor_id: @dev, actor_kind: :agent, actor_name: "keel/dev"}})
      skip = %{"verification_event_id" => 100, "skip_independence_reason" => "hotfix"}
      assert merge?(decide(put_in(s.pr.merge_request, skip)))

      plain = %{"verification_event_id" => 100, "skip_independence_reason" => nil}
      assert reason(decide(put_in(s.pr.merge_request, plain))) == :not_independent
    end

    test "3. no recorded commit, or one not pushed to this repository" do
      result = decide(snap(%{verification: %{verified_sha: nil}}))
      assert status(result) == :blocked and reason(result) == :verified_sha_missing

      # Only a rescue-branch push, or another repository's push.
      result = decide(snap(%{verification: %{verified_sha: sha("9")}}))
      assert reason(result) == :verified_sha_not_pushed
    end

    test "4. a chain through several pushes ends on the base branch" do
      pushes = [
        push(1, sha("a"), sha("0")),
        push(2, sha("b"), sha("a")),
        push(3, sha("c"), sha("b"))
      ]

      assert merge?(decide(snap(%{pushes: pushes, latest_push: List.last(pushes)})))
    end

    test "4. a chain through a later run after a rescue branch" do
      pushes = [
        push(1, sha("a"), sha("0")),
        push(2, sha("r"), sha("a"), %{rescue_branch: "hm/7/bos-12-run-2"}),
        push(3, sha("c"), sha("a"))
      ]

      assert merge?(decide(snap(%{pushes: pushes, latest_push: List.last(pushes)})))
    end

    test "4. a broken chain: a base neither pushed nor on the base branch (有人手动推过提交)" do
      pushes = [push(1, sha("a"), sha("0")), push(3, sha("c"), sha("x"))]
      g = gh(%{chain_base: %{sha("x") => "diverged"}})
      result = decide(snap(%{pushes: pushes, latest_push: List.last(pushes)}), g)
      assert status(result) == :blocked and reason(result) == :push_chain_broken
      assert elem(result, 1)[:merge_note] =~ "Commit xxxxxxx"
    end

    test "4. a cycle in the records ends without looping" do
      pushes = [push(1, sha("a"), sha("c")), push(2, sha("c"), sha("a"))]
      assert {:broken, _} = Decide.chain_end(pushes, sha("c"))

      assert reason(decide(snap(%{pushes: pushes, latest_push: List.last(pushes)}))) ==
               :push_chain_broken
    end

    test "5. an active run: waiting, without a timer (评审 Agent 的运行还没收尾)" do
      result = decide(snap(%{active_run_id: 77}))
      assert status(result) == :waiting and reason(result) == :run_active
      assert elem(result, 1)[:merge_note] == "Waiting for run #77 to finish."
      assert elem(result, 1)[:waiting_since] == nil
      assert elem(result, 0) == []
    end

    test "6. the head moved after the verification: stale" do
      result = decide(snap(), gh(%{pr: facts(%{head_sha: sha("d")})}))
      assert status(result) == :stale and reason(result) == :head_changed
      assert elem(result, 1)[:head_sha] == sha("d")
    end

    test "7. pending CI: waiting with a growing poll, blocked after 6 hours" do
      g = gh(%{checks: %{runs: [run_check("test", nil)], statuses: []}})

      assert {[{:poll, 60}], changes} = decide(snap(), g)
      assert changes[:merge_status] == :waiting and changes[:merge_reason] == :ci_pending
      assert changes[:waiting_since] == @now
      assert changes[:checks_state] == :pending

      since = DateTime.add(@now, -1800)

      s =
        snap(%{
          pr: row(%{waiting_since: since}),
          verification: %{inserted_at: DateTime.add(@now, -7200)}
        })

      assert {[{:poll, 450}], changes} = decide(s, g)
      assert changes[:waiting_since] == since

      since = DateTime.add(@now, -3 * 3600)

      s =
        snap(%{
          pr: row(%{waiting_since: since}),
          verification: %{inserted_at: DateTime.add(@now, -4 * 3600)}
        })

      assert {[{:poll, 900}], _} = decide(s, g)

      since = DateTime.add(@now, -7 * 3600)

      s =
        snap(%{
          pr: row(%{waiting_since: since}),
          verification: %{inserted_at: DateTime.add(@now, -8 * 3600)}
        })

      result = decide(s, g)
      assert {[], changes} = result
      assert status(result) == :blocked and reason(result) == :ci_timeout
      assert changes[:waiting_since] == since

      # A newer verification restarts the timer.
      s = snap(%{pr: row(%{waiting_since: since})})
      assert {[{:poll, 60}], changes} = decide(s, g)
      assert changes[:waiting_since] == @now
    end

    test "7. no checks: pending when CI is required, success otherwise" do
      g = gh(%{checks: %{runs: [], statuses: []}})
      assert reason(decide(snap(), g)) == :ci_pending
      assert merge?(decide(snap(%{project: %{require_ci: false}}), g))
    end

    test "7. commit statuses count; none at all is ignored" do
      g =
        gh(%{
          checks: %{
            runs: [run_check("test", "success")],
            statuses: [%{"context" => "ci/x", "state" => "pending"}]
          }
        })

      assert reason(decide(snap(), g)) == :ci_pending

      g = gh(%{checks: %{runs: [], statuses: [%{"context" => "ci/x", "state" => "error"}]}})
      assert {[{:auto_reopen, %{reason: :ci_failed}}], _} = decide(snap(), g)
    end

    test "7. failed CI: an automatic reopen with the failed checks (CI 失败)" do
      runs = [
        run_check("test (ubuntu)", "failure", %{
          "output" => %{"title" => "2 tests failed", "summary" => "LoginTest failed"}
        }),
        run_check("lint", "success")
      ]

      assert {[{:auto_reopen, reopen}], changes} =
               decide(snap(), gh(%{checks: %{runs: runs, statuses: []}}))

      assert reopen.verification_event_id == 100 and reopen.reason == :ci_failed
      assert reopen.content =~ "CI failed on ccccccc (pull request #12):"
      assert reopen.content =~ "- test (ubuntu): failure https://ci.example/test (ubuntu)"
      assert reopen.content =~ "2 tests failed\n\nLoginTest failed"
      refute reopen.content =~ "lint"
      assert changes[:checks_state] == :failure
      assert changes[:checks]["failed"] == ["test (ubuntu)"]
    end

    test "7. checks detail (decision 22): 5 failed names at most, truncated" do
      long = String.duplicate("a", 150)

      runs =
        for(n <- ~w(f e d c b), do: run_check(n, "failure")) ++
          [run_check(long, "timed_out"), run_check("ok", "skipped"), run_check("wip", nil)]

      {_actions, changes} = decide(snap(), gh(%{checks: %{runs: runs, statuses: []}}))
      checks = changes[:checks]
      assert checks["head_sha"] == sha("c")
      assert checks["total"] == 8 and checks["passed"] == 1 and checks["pending"] == 1
      assert length(checks["failed"]) == 5
      assert checks["failed"] == [String.duplicate("a", 100), "b", "c", "d", "e"]
    end

    test "the checks are not updated before step 7" do
      {_actions, changes} = decide(snap(%{active_run_id: 1}))
      refute Keyword.has_key?(changes, :checks)
      refute Keyword.has_key?(changes, :checks_state)
    end

    test "8. GitHub is still computing mergeability: poll in 30 seconds" do
      assert {[{:poll, 30}], _} = decide(snap(), gh(%{pr: facts(%{mergeable: nil})}))
    end

    test "the repository is unavailable: blocked without GitHub" do
      result = decide(snap(%{repository: %{available?: false}}), nil)
      assert {[], _} = result
      assert reason(result) == :repository_unavailable

      assert {[], []} =
               decide(snap(%{repository: %{available?: false}, task: %{status: :done}}), nil)
    end

    test "leaving verified drops the merge status" do
      s =
        snap(%{
          task: %{status: :in_progress},
          pr: row(%{merge_status: :stale, merge_reason: :head_changed})
        })

      assert {[:to_draft], changes} = decide(s)
      assert changes[:merge_status] == :none and changes[:merge_reason] == nil
    end
  end

  describe "add-squads decision 11: the assignee side" do
    @squad 50
    @lead 40
    @lead2 41
    @bob 70
    @outsider 60

    # web-team (@squad) led by @lead, with @dev (who pushed), @review and
    # the person @bob; `side` the side now, `recorded` the one recorded.
    defp squad_snap(verifier, opts \\ []) do
      side = Keyword.get(opts, :side, [@squad, @lead, @dev, @review, @bob])
      recorded = Keyword.get(opts, :recorded, side)

      snap(%{
        task: %{assignee_id: hd(side)},
        assignee_side: side,
        squad_names: %{@squad => "web-team"},
        verification: Map.merge(%{assignee_side_ids: recorded}, verifier)
      })
    end

    defp note(s), do: elem(decide(s), 1)[:merge_note]

    test "a member who never pushed verifies: blocked (小队成员带测试验收父任务)" do
      s = squad_snap(%{actor_id: @review, actor_kind: :agent, actor_name: "keel/review"})
      assert reason(decide(s)) == :not_independent
      assert note(s) == "Not independent: keel/review is on the assignee side (squad web-team)."
    end

    test "a reviewer the leader mentioned: blocked (leader 请来的外部评审)" do
      s =
        squad_snap(%{
          actor_id: @outsider,
          actor_kind: :agent,
          actor_name: "carol/review",
          run_causal_agent_ids: [@lead, @outsider]
        })

      assert note(s) ==
               "Not independent: carol/review verified in a run caused by the assignee side " <>
                 "(squad web-team)."
    end

    test "a person outside the squad: merged (外部的人验收小队的工作)" do
      assert merge?(decide(squad_snap(%{})))
    end

    test "a member removed after verifying: still blocked (内部验收后移出验收人)" do
      s =
        squad_snap(%{actor_id: @bob, actor_kind: :human, actor_name: "bob"},
          side: [@squad, @lead, @dev, @review],
          recorded: [@squad, @lead, @dev, @review, @bob]
        )

      assert note(s) ==
               "Not independent: bob was on the assignee side (squad web-team) when verifying."
    end

    test "the old leader replaced after verifying: still blocked (旧 leader 验收后被替换)" do
      s =
        squad_snap(%{actor_id: @lead, actor_kind: :agent, actor_name: "keel/lead"},
          side: [@squad, @lead2, @dev, @review],
          recorded: [@squad, @lead, @dev, @review]
        )

      assert reason(decide(s)) == :not_independent
      assert note(s) =~ "was on the assignee side (squad web-team)"

      # alice re-verifies: her event records the side of its moment.
      s = squad_snap(%{}, side: [@squad, @lead2, @dev, @review])
      assert merge?(decide(s))
    end

    test "a member added afterwards counts too" do
      s =
        squad_snap(%{actor_id: @bob, actor_kind: :human, actor_name: "bob"},
          recorded: [@squad, @lead, @dev, @review]
        )

      assert note(s) == "Not independent: bob is on the assignee side (squad web-team)."
    end

    test "a person assignee who verified, then reassigned (执行方本人验收后改派)" do
      s =
        snap(%{
          task: %{assignee_id: 80},
          assignee_side: [80],
          verification: %{actor_id: 81, actor_name: "carol", assignee_side_ids: [81]}
        })

      assert note(s) == "Not independent: carol was the assignee when verifying."
    end

    test "an older event without a recorded side: the current side only" do
      s =
        squad_snap(%{actor_id: @bob, actor_kind: :human, actor_name: "bob"},
          side: [@squad, @lead, @dev, @review],
          recorded: nil
        )

      assert merge?(decide(s))

      s = squad_snap(%{actor_id: @bob, actor_kind: :human, actor_name: "bob"}, recorded: [])
      assert reason(decide(s)) == :not_independent
    end
  end

  describe "decisions 8, 9: reopens used up" do
    test "failed, the question once per verification (次数用尽)" do
      g = gh(%{checks: %{runs: [run_check("test", "failure")], statuses: []}})
      s = snap(%{pr: row(%{auto_reopen_count: 3})})

      assert {[{:escalate, %{verification_event_id: 100, content: content}}], changes} =
               decide(s, g)

      assert content ==
               "@alice BOS-12 still fails (CI failed) after 3 automatic reopens. " <>
                 "A person needs to look at it: https://github.com/acme/app/pull/12"

      assert changes[:merge_status] == :failed and changes[:merge_reason] == :ci_failed_limit

      s = snap(%{pr: row(%{auto_reopen_count: 3, escalated_event_id: 100})})
      assert {[], changes} = decide(s, g)
      assert changes[:merge_reason] == :ci_failed_limit
    end
  end

  describe "merge results (decision 7 step 9)" do
    test "200, 409, required checks, rejected, conflict" do
      s = snap()
      v = s.verification

      assert {[], changes} = Decide.merge_outcome(s, s.pr, v, {:merged, sha("m")})
      assert changes[:merge_status] == :merged and changes[:merged_sha] == sha("m")

      assert reason(Decide.merge_outcome(s, s.pr, v, :head_changed)) == :head_changed

      result =
        Decide.merge_outcome(
          s,
          s.pr,
          v,
          {:not_allowed, "blocked", "Required status check \"ci\" is expected."}
        )

      assert {[{:poll, 60}], _} = result
      assert status(result) == :waiting and reason(result) == :required_checks

      result = Decide.merge_outcome(s, s.pr, v, {:not_allowed, "blocked", "Review required."})
      assert status(result) == :blocked and reason(result) == :merge_rejected
      assert elem(result, 1)[:merge_note] == "Review required. Resolve it on GitHub."

      assert {[{:auto_reopen, %{reason: :merge_conflict, content: content}}], _} =
               Decide.merge_outcome(s, s.pr, v, {:not_allowed, "dirty", "conflict"})

      assert content ==
               "Pull request #12 has merge conflicts with main. The next run merges main into " <>
                 "hm/7/bos-12; resolve the conflicts there."

      s = snap(%{pr: row(%{auto_reopen_count: 3})})
      result = Decide.merge_outcome(s, s.pr, v, {:not_allowed, "dirty", "conflict"})
      assert reason(result) == :merge_conflict_limit
      assert [{:escalate, %{content: content}}] = elem(result, 0)
      assert content =~ "(has merge conflicts)"
    end

    test "the restore of a deleted branch failed" do
      assert Decide.branch_missing()[:merge_reason] == :branch_missing
    end
  end

  test "every merge reason code has a case above" do
    covered =
      ~w(policy_manual agent_verified not_independent verified_sha_missing verified_sha_not_pushed
         push_chain_broken run_active head_changed ci_pending ci_timeout required_checks
         merge_rejected pr_closed repository_unavailable branch_missing ci_failed_limit
         merge_conflict_limit)a

    assert Enum.sort(covered) == Enum.sort(PullRequest.merge_reasons())
  end

  test "truncate keeps whole characters" do
    assert Decide.truncate("ééé", 5) == "éé"
    assert Decide.truncate("abc", 5) == "abc"
  end
end
