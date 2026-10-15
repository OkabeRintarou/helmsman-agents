defmodule HelmsmanWeb.CollabComponentsTest do
  # add-collaboration-ui 1.1: the pure texts and helpers (D3, D4, D5, D9).
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias HelmsmanWeb.CollabComponents, as: C

  defp link(type, direction, task, waiting_for \\ nil),
    do: %{
      type: type,
      direction: direction,
      task: task,
      title: task,
      status: "new",
      waiting_for: waiting_for
    }

  test "waiting_for texts, unknown included" do
    assert C.waiting_for_text("status") == "未完成"
    assert C.waiting_for_text("run") == "还有运行在进行"
    assert C.waiting_for_text("merge") == "代码还没合并"
    assert C.waiting_for_text(:steps) == "有步骤还没落地"
    assert C.waiting_for_text("later") == "未满足"
  end

  test "blockers, replacers and the locks" do
    detail = %{
      blocked: true,
      status: "new",
      links: [
        link("depends_on", "out", "BOS-1", "merge"),
        link("depends_on", "out", "BOS-2"),
        link("depends_on", "in", "WEB-9"),
        link("replaces", "in", "BOS-5")
      ]
    }

    assert C.blockers(detail) == [%{task: "BOS-1", waiting_for: "merge"}]
    assert C.replacers(detail) == ["BOS-5"]
    assert C.start_lock(detail) =~ "BOS-1"
    refute C.start_lock(detail) =~ "BOS-2"
    assert C.blocked_tooltip(detail) == "在等：BOS-1 代码还没合并"
    assert C.restore_lock(detail) =~ "已被 BOS-5 替代"
    assert C.start_lock(%{detail | blocked: false}) == nil
    # Blocked but the links were read before the flip.
    assert C.start_lock(%{blocked: true, links: []}) =~ "有未满足的前置任务"
    assert C.restore_lock(%{links: []}) == nil
  end

  test "groups in order, empty ones left out" do
    links = [link("replaces", "out", "B"), link("depends_on", "out", "A")]

    assert [{"depends-out", "依赖于", [%{task: "A"}]}, {"replaces-out", "替代了", [%{task: "B"}]}] =
             C.link_groups(links)
  end

  test "relations and ends" do
    assert C.relation("depends-out", "A", "B") == {"depends_on", "A", "B"}
    assert C.relation("depends-in", "A", "B") == {"depends_on", "B", "A"}
    assert C.relation("replaces-out", "A", "B") == {"replaces", "A", "B"}
    assert C.relation("replaces-in", "A", "B") == {"replaces", "B", "A"}
    assert C.relation("relates", "A", "B") == nil
    assert C.ends(%{direction: "in", task: "B"}, "A") == {"B", "A"}
  end

  test "consequences" do
    assert {:info, _} = C.consequence("depends_on", %{id: "A"}, %{id: "B"})

    assert {:warning, text} =
             C.consequence("replaces", %{id: "A"}, %{id: "B", status: "in_progress"})

    assert text =~ "B 现在是进行中"
    assert {:info, text} = C.consequence("replaces", %{id: "A"}, %{id: "B", status: "done"})
    assert text =~ "只记录关联"
  end

  test "link errors" do
    assert C.link_error({:cycle, ["BOS-1", "BOS-2", "BOS-1"]}) == "会形成循环：BOS-1 → BOS-2 → BOS-1"
    assert C.link_error(:self_link) == "任务不能关联自己"
    assert C.link_error({:not_found, "X-1"}) == "任务 X-1 不存在"
    assert C.link_error(:other) == nil
  end

  test "status counts skip zeros; progress without steps" do
    progress = %{total: 3, done: 1, by_status: %{"new" => 2, "done" => 1, "verified" => 0}}
    assert C.status_counts(progress) == [{"new", 2}, {"done", 1}]
    assert C.status_counts(nil) == []
  end

  test "mention notes: only skipped mentions" do
    dispatch = [
      %{agent: "keel/c", trigger: "mention", result: "skipped", reason: "unauthorized"},
      %{agent: "keel/x", trigger: "mention", result: "skipped", reason: "agent_disabled"},
      %{agent: "keel/y", trigger: "mention", result: "skipped", reason: "mystery"},
      %{agent: "keel/dev", trigger: "mention", result: "queued", reason: nil},
      %{agent: "keel/z", trigger: "steer", result: "skipped", reason: "rate_limited"},
      %{agent: nil, trigger: "mention", result: "skipped", reason: "unauthorized"}
    ]

    assert C.mention_notes(dispatch) == %{
             "keel/c" => "触发者无权触发它",
             "keel/x" => "它已停用",
             "keel/y" => "没有启动"
           }

    assert C.mention_notes(nil) == %{}
  end

  test "steer state, first that holds" do
    at = DateTime.utc_now()
    steer = %{run_id: 7, agent: "keel/dev", sent_at: at, acked_at: nil}
    assert {:sent, _} = C.steer_state(%{steer: steer, dispatch: []})
    assert {:acked, _} = C.steer_state(%{steer: %{steer | acked_at: at}, dispatch: []})

    skipped = %{trigger: "steer", result: "skipped", agent: "keel/dev", reason: "rate_limited"}
    assert {:skipped, ^skipped} = C.steer_state(%{steer: nil, dispatch: [skipped]})

    queued = %{trigger: "steer", result: "queued", agent: "keel/dev", steer_run_id: 7}
    assert {:queued, ^queued} = C.steer_state(%{steer: nil, dispatch: [queued]})
    assert C.steer_state(%{steer: nil, dispatch: []}) == nil
  end

  test "mention candidates" do
    availability = %{
      "keel/c" => %{result: {:skipped, :unauthorized}},
      "keel/dev" => %{result: :ok}
    }

    candidates = [
      %{name: "alice", kind: "human"},
      %{name: "keel/c", kind: "agent", managed?: true},
      %{name: "keel/dev", kind: "agent", managed?: true},
      %{name: "keel/cli", kind: "agent", managed?: false}
    ]

    assert [
             %{name: "alice"} = alice,
             %{name: "keel/c", muted: true, note: c},
             %{name: "keel/dev"} = dev,
             %{name: "keel/cli", muted: true, note: cli}
           ] = C.mention_candidates(candidates, availability)

    refute Map.has_key?(alice, :note)
    refute Map.has_key?(dev, :note)
    assert c == "@ 不会启动它：你无权触发 keel/c"
    assert cli == "外接 Agent，@ 不会唤醒它"
  end

  describe "被覆盖的提及 (add-nested-feedback-replies D12)" do
    defp line(dispatch) do
      Phoenix.LiveViewTest.render_component(&C.dispatch_line/1,
        entry: %{dispatch: dispatch},
        dom_id: "feedback-6",
        uri: "/w/acme/t/BOS-12"
      )
      |> LazyHTML.from_fragment()
    end

    defp item(doc, i), do: LazyHTML.query(doc, "#feedback-6-dispatch-#{i}")

    defp item(agent, trigger, result, reason \\ nil, run_id \\ nil),
      do: %{
        agent: agent,
        trigger: trigger,
        result: result,
        reason: reason,
        run_id: run_id,
        squad: nil
      }

    test "回答覆盖提及" do
      dispatch = [
        item("keel/dev", "answer", "queued", nil, 41),
        item("keel/dev", "mention", "skipped", "covered")
      ]

      doc = line(dispatch)
      assert LazyHTML.text(item(doc, 0)) =~ "回答"

      assert item(doc, 0) |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
               "/w/acme/t/BOS-12?run=41"
             ]

      assert LazyHTML.text(item(doc, 1)) =~ "提及"
      assert LazyHTML.text(item(doc, 1)) =~ "keel/dev：已由这条记录的回答唤醒"
      assert LazyHTML.attribute(item(doc, 1), "data-covered") == ["true"]
      assert LazyHTML.attribute(item(doc, 1), "data-skipped") == []
      assert C.mention_notes(dispatch) == %{}
    end

    test "a callback covers the mention" do
      dispatch = [
        item("keel/dev", "requested", "merged", nil, 41),
        item("keel/dev", "mention", "skipped", :covered)
      ]

      assert LazyHTML.text(item(line(dispatch), 1)) =~ "已由这条记录的回调唤醒"
      assert C.mention_notes(dispatch) == %{}
    end

    test "回答被跳过、提及唤醒" do
      dispatch = [
        item("keel/dev", "answer", "skipped", "no_grant"),
        item("keel/dev", "mention", "queued", nil, 42)
      ]

      doc = line(dispatch)
      assert LazyHTML.attribute(item(doc, 0), "data-skipped") == ["true"]
      refute LazyHTML.text(doc) =~ "已由"

      assert item(doc, 1) |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
               "/w/acme/t/BOS-12?run=42"
             ]

      assert C.mention_notes(dispatch) == %{}
    end

    test "都被跳过" do
      dispatch = [
        item("keel/dev", "answer", "skipped", "no_grant"),
        item("keel/dev", "mention", "skipped", "unauthorized")
      ]

      doc = line(dispatch)
      assert LazyHTML.attribute(item(doc, 0), "data-skipped") == ["true"]
      assert LazyHTML.attribute(item(doc, 1), "data-skipped") == ["true"]
      assert LazyHTML.text(item(doc, 1)) =~ "触发者无权触发它"
      refute LazyHTML.text(doc) =~ "已由"
      assert C.mention_notes(dispatch) == %{"keel/dev" => "触发者无权触发它"}
    end
  end
end
