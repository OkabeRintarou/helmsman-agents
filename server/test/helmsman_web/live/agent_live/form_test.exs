defmodule HelmsmanWeb.AgentLive.FormTest do
  @moduledoc "Spec web-agents 新建与编辑 Agent、Agent 页实时刷新的面板部分 (design D5)."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Agents
  alias HelmsmanWeb.AgentForm

  setup %{conn: conn} do
    _admin = user_fixture()
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    adam = user_fixture(%{display_name: "adam"})
    bob = user_fixture(%{display_name: "bob"})
    member_fixture(ws, adam, :admin)
    member_fixture(ws, bob, :member)
    alice_scope = workspace_scope_fixture(alice, ws)

    {mbp, _} = daemon_fixture(alice, %{name: "mbp", workspace_ids: [ws.id]})
    claude = runtime_fixture(ws, mbp, %{provider: "claude", models: ["opus", "sonnet"]})
    codex = runtime_fixture(ws, mbp, %{provider: "codex"})
    {bob_box, _} = daemon_fixture(bob, %{name: "bob-box", workspace_ids: [ws.id]})
    bob_codex = runtime_fixture(ws, bob_box, %{provider: "codex"})

    managed_agent_fixture(alice_scope, %{
      name: "keel/dev",
      runtime_id: claude.id,
      description: "原描述",
      env: %{"A" => "1", "B" => "2"},
      extra_mcp_servers: %{"gh" => %{"command" => "x"}}
    })

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, adam: adam, bob: bob},
      alice_scope: alice_scope,
      claude: claude,
      codex: codex,
      bob_codex: bob_codex,
      agents: "/w/#{ws.slug}/agents",
      edit: "/w/#{ws.slug}/agents/keel/dev?panel=edit"
    }
  end

  defp open(ctx, who, path), do: live(log_in_user(ctx.conn, ctx.users[who]), path)
  defp agent(ctx), do: elem(Agents.get(ctx.alice_scope, "keel/dev"), 1)
  defp in_panel?(view, selector, text \\ nil), do: in_portal?(view, "agent-panel", selector, text)

  defp option_texts(view, select),
    do:
      view
      |> portal("agent-panel")
      |> LazyHTML.query("#{select} option")
      |> Enum.map(&LazyHTML.text/1)

  defp new_params(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "keel/new",
        "description" => "",
        "provider" => "claude",
        "runtime_id" => to_string(ctx.claude.id),
        "model" => "",
        "effort" => "",
        "instructions" => "",
        "custom_args" => "",
        "access" => "owner_only",
        "access_member_ids" => [""],
        "capabilities" => [""],
        "max_concurrency" => "2",
        "timeout_minutes" => "120",
        "idle_timeout_minutes" => "20",
        "env_delete" => [""],
        "mcp" => ""
      },
      overrides
    )
  end

  # add-agent-conversation-ui D12: web-agents 对话创建的入口.
  describe "对话创建的入口" do
    test "从新建面板进入", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      slug = ctx.agents |> String.split("/") |> Enum.at(2)

      assert in_portal?(
               view,
               "agent-panel",
               ~s(#agent-form-design a[href="/w/#{slug}/agent-design"]),
               "和 AI 对话创建"
             )

      assert in_portal?(view, "agent-panel", "#agent-form-design", "不确定怎么配？")
    end

    test "编辑面板没有入口", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.edit)
      assert open?(view, "agent-panel")
      refute in_portal?(view, "agent-panel", "#agent-form-design")
    end
  end

  describe "new" do
    test "新建 Agent opens only the agent form, not the shell's 新建任务", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents)
      assert has_element?(view, ~s(#agents-new[href="#{ctx.agents}?panel=new-agent"]))

      view |> element("#agents-new") |> render_click()
      assert_patch(view, ctx.agents <> "?panel=new-agent")
      assert open?(view, "agent-panel")
      refute open?(view, "new-task-dialog")
    end

    test "the shell's ?panel=new opens 新建任务, not the agent form", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new")
      assert open?(view, "new-task-dialog")
      refute open?(view, "agent-panel")
    end

    test "creating goes to the new agent with the defaults", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents)
      view |> element("#agents-new") |> render_click()
      assert open?(view, "agent-panel")
      assert portal_attr(view, "agent-panel", "#agent-max-concurrency", "value") == "2"

      render_submit(view, "agent_form_submit", %{"agent" => new_params(ctx)})
      {path, flash} = assert_redirect(view)
      assert path == ctx.agents <> "/keel/new"
      assert flash["info"] =~ "keel/new"

      {:ok, view, _html} = open(ctx, :alice, path)
      assert has_element?(view, "#agent-properties [data-access]", "仅所属用户")
      assert has_element?(view, "#agent-properties [data-max-concurrency]", "2")
      assert has_element?(view, "#agent-properties [data-runtime-row]", "mbp")
    end

    test "the runtime menu lists only the user's runtimes of the CLI", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      assert option_texts(view, "#agent-runtime") == ["不绑定", "mbp · 在线"]

      render_change(view, "agent_form_change", %{"agent" => new_params(ctx)})

      render_change(view, "agent_form_change", %{
        "agent" => new_params(ctx, %{"provider" => "codex"})
      })

      assert option_texts(view, "#agent-runtime") == ["不绑定", "mbp · 在线"]

      values =
        view
        |> portal("agent-panel")
        |> LazyHTML.query("#agent-runtime option")
        |> LazyHTML.attribute("value")

      assert values == ["", to_string(ctx.codex.id)]
      refute to_string(ctx.bob_codex.id) in values
      # The claude runtime chosen before was cleared.
      assert portal_attr(view, "agent-panel", "#agent-runtime option[selected]", "value") in [
               nil,
               ""
             ]
    end

    test "models come from the runtime, free text without a list", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      render_change(view, "agent_form_change", %{"agent" => new_params(ctx)})
      assert option_texts(view, "#agent-model") == ["CLI 缺省", "opus", "sonnet"]

      render_change(view, "agent_form_change", %{
        "agent" => new_params(ctx, %{"runtime_id" => ""})
      })

      assert in_panel?(view, ~s(input#agent-model))
    end

    test "a name already taken", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")

      render_submit(view, "agent_form_submit", %{
        "agent" => new_params(ctx, %{"name" => "keel/dev", "description" => "保留"})
      })

      assert open?(view, "agent-panel")
      assert view |> portal("agent-panel") |> LazyHTML.to_html() =~ "已被占用"
      assert in_panel?(view, "#agent-description", "保留")
    end
  end

  describe "edit" do
    test "an admin editing someone else's agent changes only description and limits", ctx do
      {:ok, view, _html} = open(ctx, :adam, ctx.edit)

      assert in_panel?(view, "#agent-form-execution[disabled]")
      assert in_panel?(view, "#agent-form-access[disabled]")
      assert in_panel?(view, "#agent-form-secrets[disabled]")
      assert in_panel?(view, "#agent-form-locked", "只有所属用户能修改执行配置")

      before = agent(ctx)

      render_submit(view, "agent_form_submit", %{
        "agent" =>
          new_params(ctx, %{
            "description" => "原描述",
            "provider" => "codex",
            "runtime_id" => "",
            "access" => "workspace",
            "max_concurrency" => "4"
          })
      })

      after_ = agent(ctx)
      assert after_.max_concurrency == 4
      assert after_.provider == before.provider
      assert after_.runtime == before.runtime
      assert after_.access == before.access
      assert after_.env_names == before.env_names
      assert has_element?(view, "#agent-properties [data-max-concurrency]", "4")
      refute open?(view, "agent-panel")
    end

    test "deleting and adding variables", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.edit)
      render_click(view, "agent_form_add_env", %{})

      render_submit(view, "agent_form_submit", %{
        "agent" => %{
          "env_delete" => ["", "B"],
          "env_new" => %{"A" => ""},
          "env_add" => %{"1" => %{"name" => "C", "value" => "3"}}
        }
      })

      assert agent(ctx).env_names == ["A", "C"]
      assert has_element?(view, "#agent-properties [data-env-names]", "C")
    end

    test "an invalid variable name: the error under 密钥, no value in the page", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.edit)
      render_click(view, "agent_form_add_env", %{})

      html =
        render_submit(view, "agent_form_submit", %{
          "agent" => %{"env_add" => %{"1" => %{"name" => "HELMSMAN_X", "value" => "x1"}}}
        })

      assert open?(view, "agent-panel")
      assert in_panel?(view, "#agent-secrets-error", "HELMSMAN_X")
      refute html =~ "x1"
      refute view |> portal("agent-panel") |> LazyHTML.to_html() =~ "x1"
      refute :sys.get_state(view.pid) |> inspect(limit: :infinity) =~ ~s("x1")
    end

    test "secret inputs are empty password fields in ignored containers of the panel's generation",
         ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.edit)

      assert in_panel?(
               view,
               ~s(#agent-form-1-env-A[phx-update="ignore"] input[type="password"][value=""])
             )

      assert in_panel?(view, ~s(#agent-form-1-mcp[phx-update="ignore"] textarea))

      render_patch(view, "/w/#{ctx.ws.slug}/agents/keel/dev")
      render_patch(view, ctx.edit)
      assert in_panel?(view, ~s(#agent-form-2-env-A[phx-update="ignore"]))
    end

    test "MCP input that is not a JSON object is refused locally", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.edit)

      render_submit(view, "agent_form_submit", %{
        "agent" => %{"mcp" => "[1, 2]", "description" => "新"}
      })

      assert in_panel?(view, "#agent-secrets-error", "JSON 对象")
      assert agent(ctx).description == "原描述"
      assert agent(ctx).extra_mcp_server_names == ["gh"]
    end

    test "清除全部 removes every MCP server", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.edit)

      render_submit(view, "agent_form_submit", %{"agent" => %{"mcp" => "", "mcp_clear" => "true"}})

      assert agent(ctx).extra_mcp_server_names == []
    end

    test "a change elsewhere shows a notice and keeps the input; archiving blocks the submit",
         ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.edit)
      render_change(view, "agent_form_change", %{"agent" => %{"description" => "我的输入"}})

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{description: "别人改的"})
      send(view.pid, :reload)

      assert in_panel?(view, "#agent-form-notice", "keel/dev 已被修改")
      assert in_panel?(view, "#agent-description", "我的输入")

      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")
      send(view.pid, :reload)
      assert in_panel?(view, "#agent-form-notice", "已归档")
      assert in_panel?(view, "#agent-form-submit[disabled]")
    end
  end

  describe "attrs/2" do
    setup ctx do
      {:ok, view} = Agents.get(ctx.alice_scope, "keel/dev")
      view = Map.merge(view, %{workspace_id: ctx.ws.id, actor_id: nil})
      %{view: view}
    end

    test "only the changed fields of an edit", ctx do
      form = AgentForm.edit(ctx.alice_scope, 1, ctx.view, %{configure: true, administer: true})
      form = %{form | params: %{form.params | "description" => "新描述"}}
      assert {:ok, %{description: "新描述"} = attrs} = AgentForm.attrs(form, %{})
      assert map_size(attrs) == 1
    end

    test "arguments by line, member ids as integers, CLI default as nil", ctx do
      form = AgentForm.edit(ctx.alice_scope, 1, ctx.view, %{configure: true, administer: true})

      params = %{
        form.params
        | "custom_args" => "--a\n\n  \n--b x\r\n",
          "access" => "members",
          "access_member_ids" => [to_string(ctx.users.bob.id)],
          "model" => "opus"
      }

      assert {:ok, attrs} = AgentForm.attrs(%{form | params: params}, %{})
      assert attrs.custom_args == ["--a", "--b x"]
      assert attrs.access_member_ids == [ctx.users.bob.id]
      assert attrs.model == "opus"

      # The CLI default (an empty choice) is nil, here equal to the stored value.
      assert {:ok, attrs} = AgentForm.attrs(%{form | params: %{params | "model" => ""}}, %{})
      refute Map.has_key?(attrs, :model)
    end

    test "a variable value without a name is a local error", ctx do
      form = AgentForm.edit(ctx.alice_scope, 1, ctx.view, %{configure: true, administer: true})

      assert {:local, %{secrets: ["请填写变量名"]}} =
               AgentForm.attrs(form, %{"env_add" => %{"1" => %{"name" => " ", "value" => "v"}}})
    end
  end
end
