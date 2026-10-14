defmodule HelmsmanWeb.AgentDesignLive do
  @moduledoc """
  `/w/:slug/agent-design` (spec web-agent-design; add-agent-conversation-ui D1–D12): the
  current user's creation conversation — the start area when there is none, otherwise
  the conversation (messages, the current turn, the input) and the live draft (cards,
  the draft panel, confirm and discard).

  Entering a conversation checks it, subscribes to `agent_design:<id>`, then reads it
  again as the base (D2); every `{:agent_design, id}` reads it again. The current turn
  follows `view.current_run` (`HelmsmanWeb.AgentDesignTurn`). The shell forwards
  `{:agents_changed}` and `{:runtimes_changed}` (helpers, runtime names and status);
  the user's `{:provider_accounts_changed}` refreshes the account names.

  Nothing secret is read: helpers come with name, CLI, owner and dispatchability only,
  runtimes and accounts are resolved to names, the draft has no secret fields.

  A conversation may design a squad (add-squads-autopilots-ui D16): the start area's
  kind choice (`?kind=squad` preselects it), the squad block above the cards
  (`HelmsmanWeb.AgentDesignSquad`), its `SquadForm` `:draft` panel and the squad in the
  confirmation.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AgentDesignComponents
  import HelmsmanWeb.AgentComponents, only: [provider_label: 1]

  alias Helmsman.{Actors, AgentDesigns, Events, ProviderAccounts, Runtimes}

  alias HelmsmanWeb.{
    AgentDesignSquad,
    AgentDesignTurn,
    AgentForm,
    FormErrors,
    RunLog,
    SquadForm,
    Url
  }

  alias HelmsmanWeb.Components.Menu

  @max_bytes 8192
  @max_messages 40
  @max_agents 8

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: Events.subscribe(ProviderAccounts.topic(scope.user.id))

    socket =
      socket
      |> assign(
        page_title: dgettext("ui", "用对话创建 Agent"),
        forbidden?: false,
        helpers: [],
        design: nil,
        max_seq: 0,
        turn: nil,
        message: "",
        input_gen: 0,
        helper_choice: nil,
        kind_choice: if(params["kind"] == "squad", do: "squad", else: "agent"),
        start_errors: %{},
        message_errors: [],
        send_warning: nil,
        lookup: %{runtimes: %{}, accounts: %{}},
        humans: MapSet.new(),
        agent_form: nil,
        squad_form: nil,
        squad_invalid: nil,
        form_gen: 0,
        confirming: nil,
        invalid: nil,
        removing: nil,
        discarding?: false,
        tab: :chat,
        draft_dot?: false,
        highlight: %{names: MapSet.new(), version: 0}
      )
      |> stream_configure(:messages, dom_id: &"msg-#{&1.seq}")
      |> stream(:messages, [])

    case AgentDesigns.helpers(scope) do
      {:ok, helpers} ->
        socket = socket |> put_helpers(helpers) |> load_lookup()

        case AgentDesigns.current(scope) do
          {:ok, %{} = view} -> {:ok, enter(socket, view)}
          _ -> {:ok, socket}
        end

      {:error, _forbidden} ->
        {:ok, assign(socket, :forbidden?, true)}
    end
  end

  ## Reading

  defp put_helpers(socket, helpers) do
    helpers = sort_helpers(helpers, socket.assigns.current_scope)
    choice = socket.assigns.helper_choice

    choice =
      if Enum.any?(helpers, &(&1.name == choice and &1.dispatchability == :ok)),
        do: choice,
        else: Enum.find_value(helpers, &(&1.dispatchability == :ok && &1.name))

    assign(socket, helpers: helpers, helper_choice: choice)
  end

  defp reload_helpers(socket) do
    case AgentDesigns.helpers(socket.assigns.current_scope) do
      {:ok, helpers} -> put_helpers(socket, helpers)
      _ -> socket
    end
  end

  # The user's runtimes and accounts by ID, to show what a draft agent is bound to.
  defp load_lookup(socket) do
    scope = socket.assigns.current_scope

    runtimes =
      case Runtimes.list(scope) do
        {:ok, list} -> Map.new(list, &{&1.id, &1})
        _ -> %{}
      end

    accounts =
      case ProviderAccounts.list(scope) do
        {:ok, list} -> Map.new(list, &{&1.id, Map.take(&1, [:id, :name, :cli])})
        _ -> %{}
      end

    # The workspace's people, to tell them from agents among the squad's members.
    humans =
      case Actors.list_assignable(scope) do
        {:ok, actors} ->
          for %{kind: :human, name: name} <- actors, into: MapSet.new(), do: String.downcase(name)

        _ ->
          MapSet.new()
      end

    assign(socket, lookup: %{runtimes: runtimes, accounts: accounts}, humans: humans)
  end

  # Check, subscribe, read again (D2).
  defp enter(socket, view) do
    if connected?(socket) do
      Events.subscribe(AgentDesigns.topic(view.id))

      case AgentDesigns.get(socket.assigns.current_scope, view.id) do
        {:ok, fresh} -> show(socket, fresh, true)
        {:error, _} -> gone(socket)
      end
    else
      show(socket, view, true)
    end
  end

  defp reread(%{assigns: %{design: %{id: id}}} = socket) do
    case AgentDesigns.get(socket.assigns.current_scope, id) do
      {:ok, view} -> show(socket, view, false)
      {:error, _} -> gone(socket)
    end
  end

  defp reread(socket), do: socket

  # The conversation is gone (cleaned up, the user removed …): back to the start area.
  defp gone(socket) do
    socket
    |> leave()
    |> put_flash(:error, dgettext("ui", "对话已不存在"))
  end

  defp leave(socket) do
    if design = socket.assigns.design,
      do: Phoenix.PubSub.unsubscribe(Helmsman.PubSub, AgentDesigns.topic(design.id))

    socket
    |> assign(
      design: nil,
      max_seq: 0,
      turn: AgentDesignTurn.close(socket.assigns.turn),
      agent_form: nil,
      squad_form: nil,
      squad_invalid: nil,
      confirming: nil,
      invalid: nil,
      removing: nil,
      discarding?: false,
      send_warning: nil,
      message_errors: [],
      draft_dot?: false
    )
    |> stream(:messages, [], reset: true)
  end

  defp show(socket, view, reset?) do
    previous = socket.assigns.design
    socket = if reset?, do: stream(socket, :messages, [], reset: true), else: socket
    max_seq = if reset?, do: 0, else: socket.assigns.max_seq
    fresh = Enum.filter(view.messages, &(&1.seq > max_seq))
    max_seq = Enum.reduce(fresh, max_seq, &max(&1.seq, &2))

    turn =
      cond do
        view.status != :open ->
          AgentDesignTurn.close(socket.assigns.turn)

        connected?(socket) ->
          AgentDesignTurn.sync(
            socket.assigns.turn,
            socket.assigns.current_scope,
            view.current_run
          )

        true ->
          nil
      end

    if view.status != :open and connected?(socket),
      do: Phoenix.PubSub.unsubscribe(Helmsman.PubSub, AgentDesigns.topic(view.id))

    socket
    |> stream(:messages, fresh)
    |> assign(design: view, max_seq: max_seq, turn: turn)
    |> track_draft(previous, view)
    |> check_confirming(view)
    |> close_panel_if_closed(view)
    |> refresh_squad_form(previous, view)
  end

  # The open squad panel follows the draft's new agents (its candidates), keeping the input.
  defp refresh_squad_form(%{assigns: %{squad_form: %{} = form}} = socket, previous, view) do
    if previous && previous.draft_version == view.draft_version,
      do: socket,
      else:
        assign(
          socket,
          :squad_form,
          SquadForm.refresh(form, socket.assigns.current_scope, view.draft)
        )
  end

  defp refresh_squad_form(socket, _previous, _view), do: socket

  # Cards whose content changed get the highlight; errors of a refused confirmation stay
  # until the draft changes; the narrow-screen 草稿 tab gets its dot.
  defp track_draft(socket, %{id: id, draft_version: v}, %{id: id, draft_version: v}), do: socket

  defp track_draft(socket, previous, view) do
    old =
      case previous do
        %{id: id, draft: draft} when id == view.id -> Map.new(agents(draft), &{&1["name"], &1})
        _ -> nil
      end

    changed =
      if old,
        do: for(a <- agents(view.draft), old[a["name"]] != a, into: MapSet.new(), do: a["name"]),
        else: MapSet.new()

    socket
    |> assign(
      highlight: %{names: changed, version: view.draft_version},
      invalid: nil,
      squad_invalid: nil,
      draft_dot?: socket.assigns.draft_dot? or (old != nil and socket.assigns.tab == :chat)
    )
  end

  # The confirmation dialog shows a snapshot: any change closes it (D8).
  defp check_confirming(%{assigns: %{confirming: nil}} = socket, _view), do: socket

  defp check_confirming(socket, view) do
    snapshot = socket.assigns.confirming

    cond do
      view.draft_version != snapshot.version ->
        socket
        |> assign(:confirming, nil)
        |> put_flash(:error, dgettext("ui", "草稿刚被更新，请检查后再确认"))

      view.current_run != nil or view.status != :open ->
        assign(socket, :confirming, nil)

      true ->
        socket
    end
  end

  defp close_panel_if_closed(socket, %{status: :open}), do: socket

  defp close_panel_if_closed(socket, _view),
    do: assign(socket, agent_form: nil, squad_form: nil, removing: nil, discarding?: false)

  defp agents(%{"agents" => agents}) when is_list(agents), do: agents
  defp agents(_draft), do: []

  ## Events: start area (D3)

  @impl true
  def handle_event("start_change", params, socket) do
    helper = params["helper"]

    socket =
      if is_binary(helper) and Enum.any?(socket.assigns.helpers, &(&1.name == helper)),
        do: assign(socket, :helper_choice, helper),
        else: socket

    {:noreply,
     assign(socket,
       message: params["message"] || socket.assigns.message,
       kind_choice: kind_param(params["kind"], socket.assigns.kind_choice)
     )}
  end

  def handle_event("start", params, socket) do
    text = params["message"] || ""
    helper = params["helper"] || socket.assigns.helper_choice
    kind = kind_param(params["kind"], socket.assigns.kind_choice)

    socket =
      assign(socket, message: text, helper_choice: helper, kind_choice: kind, start_errors: %{})

    result =
      AgentDesigns.start(socket.assigns.current_scope, %{
        helper: helper,
        message: text,
        kind: kind
      })

    {:noreply, started(socket, result, helper)}
  end

  ## Events: conversation (D4, D5)

  def handle_event("message_change", params, socket),
    do: {:noreply, assign(socket, message: params["message"] || "")}

  def handle_event("send", params, %{assigns: %{design: %{} = design}} = socket) do
    text = params["message"] || ""
    socket = assign(socket, message: text, message_errors: [], send_warning: nil)

    case AgentDesigns.send(socket.assigns.current_scope, design.id, text) do
      {:ok, view} ->
        {:noreply,
         socket
         |> assign(message: "", input_gen: socket.assigns.input_gen + 1)
         |> show(view, false)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :message_errors, message_errors(cs))}

      {:error, reason} when reason in [:turn_running, :turn_limit, :design_closed] ->
        socket = reread(socket)
        {:noreply, put_flash(socket, :error, error_text(reason, helper_name(socket)))}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, socket |> reread() |> put_flash(:error, error_text(reason, nil))}

      {:error, reason} ->
        {:noreply, assign(socket, :send_warning, error_text(reason, helper_name(socket)))}
    end
  end

  def handle_event("stop_turn", _params, %{assigns: %{design: %{} = design}} = socket) do
    case AgentDesigns.stop_turn(socket.assigns.current_scope, design.id) do
      {:ok, view} ->
        {:noreply, show(socket, view, false)}

      {:error, reason} ->
        {:noreply, socket |> reread() |> put_flash(:error, error_text(reason, nil))}
    end
  end

  def handle_event(
        "change_helper",
        %{"name" => name},
        %{assigns: %{design: %{} = design}} = socket
      ) do
    case AgentDesigns.change_helper(socket.assigns.current_scope, design.id, name) do
      {:ok, view} ->
        {:noreply, socket |> assign(:send_warning, nil) |> show(view, false)}

      {:error, reason} ->
        {:noreply, socket |> reread() |> put_flash(:error, error_text(reason, name))}
    end
  end

  ## Events: draft (D6, D7)

  def handle_event("add_agent", _params, %{assigns: %{design: %{}}} = socket) do
    if locked_reason(socket.assigns) || length(agents(socket.assigns.design.draft)) >= @max_agents do
      {:noreply, socket}
    else
      gen = socket.assigns.form_gen + 1
      form = AgentForm.draft_new(socket.assigns.current_scope, gen)
      {:noreply, assign(socket, form_gen: gen, agent_form: seen(form, socket))}
    end
  end

  def handle_event("edit_agent", %{"name" => name}, %{assigns: %{design: %{}}} = socket) do
    case {locked_reason(socket.assigns), find_agent(socket, name)} do
      {nil, %{} = entry} ->
        gen = socket.assigns.form_gen + 1
        errors = invalid_errors(socket.assigns.invalid, entry["name"])
        form = AgentForm.draft_edit(socket.assigns.current_scope, gen, entry, errors)
        {:noreply, assign(socket, form_gen: gen, agent_form: seen(form, socket))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_panel", _params, socket),
    do: {:noreply, assign(socket, :agent_form, nil)}

  def handle_event(
        "agent_form_submit",
        params,
        %{assigns: %{agent_form: %{} = form, design: %{} = design}} = socket
      ) do
    if locked_reason(socket.assigns) do
      {:noreply, socket}
    else
      {form, attrs} = AgentForm.draft_submit(form, params)
      scope = socket.assigns.current_scope

      # The version the panel last showed: a change made meanwhile (AI, another tab) is
      # `stale` and merged instead of being overwritten (D7).
      version = Map.get(form, :draft_version, design.draft_version)

      case AgentDesigns.put_agent(scope, design.id, version, attrs) do
        {:ok, view} ->
          {:noreply, socket |> assign(:agent_form, nil) |> show(view, false)}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, assign(socket, :agent_form, AgentForm.draft_errors(form, cs))}

        {:error, :stale} ->
          socket = reread(socket)
          fresh = socket.assigns.design && find_agent(socket, form.name)

          {:noreply,
           assign(socket, :agent_form, form |> AgentForm.rebase(scope, fresh) |> seen(socket))}

        {:error, :design_closed} ->
          {:noreply, socket |> assign(:agent_form, nil) |> reread()}

        {:error, :turn_running} ->
          {:noreply, socket |> assign(:agent_form, form) |> reread()}

        {:error, reason} ->
          {:noreply,
           assign(socket, :agent_form, %{form | error: error_text(reason, helper_name(socket))})}
      end
    end
  end

  def handle_event("agent_form_" <> _ = event, params, %{assigns: %{agent_form: %{}}} = socket) do
    case AgentForm.handle_event(event, params, socket) do
      {:noreply, socket} -> {:noreply, socket}
      {:saved, _view, socket} -> {:noreply, socket}
    end
  end

  def handle_event("ask_remove", %{"name" => name}, socket) do
    entry = locked_reason(socket.assigns) == nil && find_agent(socket, name)

    cond do
      !entry ->
        {:noreply, socket}

      AgentDesignSquad.references?(socket.assigns.design.draft, entry["name"]) ->
        {:noreply, put_flash(socket, :error, AgentDesignSquad.referenced_text(entry["name"]))}

      true ->
        {:noreply, assign(socket, :removing, name)}
    end
  end

  def handle_event("remove", %{"name" => name}, %{assigns: %{design: %{} = design}} = socket) do
    socket = assign(socket, :removing, nil)

    case AgentDesigns.remove_agent(
           socket.assigns.current_scope,
           design.id,
           design.draft_version,
           name
         ) do
      {:ok, view} ->
        {:noreply, show(socket, view, false)}

      {:error, reason} ->
        {:noreply,
         socket |> reread() |> put_flash(:error, error_text(reason, helper_name(socket)))}
    end
  end

  def handle_event("dismiss_remove", _params, socket),
    do: {:noreply, assign(socket, :removing, nil)}

  ## Events: the squad part (D16)

  def handle_event("edit_squad", _params, %{assigns: %{design: %{} = design}} = socket) do
    if AgentDesignSquad.squad?(design) and locked_reason(socket.assigns) == nil do
      gen = socket.assigns.form_gen + 1

      form =
        SquadForm.draft(socket.assigns.current_scope, gen, design, socket.assigns.squad_invalid)

      {:noreply, assign(socket, form_gen: gen, squad_form: form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_squad_panel", _params, socket),
    do: {:noreply, assign(socket, :squad_form, nil)}

  def handle_event(
        "squad_form_submit",
        params,
        %{assigns: %{squad_form: %{mode: :draft} = form, design: %{} = design}} = socket
      ) do
    if locked_reason(socket.assigns) do
      {:noreply, socket}
    else
      form = SquadForm.change(%{form | notice: nil, error: nil}, params)
      attrs = SquadForm.draft_attrs(form)

      result =
        AgentDesigns.put_squad(socket.assigns.current_scope, design.id, form.version, attrs)

      {:noreply, squad_saved(socket, form, result)}
    end
  end

  def handle_event("squad_form_" <> _ = event, params, %{assigns: %{squad_form: %{}}} = socket) do
    case SquadForm.handle_event(event, params, socket) do
      {:noreply, socket} -> {:noreply, socket}
      _other -> {:noreply, socket}
    end
  end

  ## Events: confirm and discard (D8)

  def handle_event("ask_confirm", _params, %{assigns: %{design: %{} = design}} = socket) do
    if confirm_reason(socket.assigns) == nil,
      do:
        {:noreply,
         assign(socket, :confirming, %{
           version: design.draft_version,
           agents: agents(design.draft),
           squad: AgentDesignSquad.squad?(design) && AgentDesignSquad.squad(design.draft),
           summary: design[:trigger_summary]
         })},
      else: {:noreply, socket}
  end

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirming, nil)}

  def handle_event("confirm", params, %{assigns: %{design: %{} = design}} = socket) do
    version = confirm_version(socket.assigns.confirming, params["version"])
    socket = assign(socket, :confirming, nil)

    if version,
      do:
        {:noreply,
         confirmed(socket, AgentDesigns.confirm(socket.assigns.current_scope, design.id, version))},
      else: {:noreply, socket}
  end

  def handle_event("ask_discard", _params, socket),
    do: {:noreply, assign(socket, :discarding?, true)}

  def handle_event("dismiss_discard", _params, socket),
    do: {:noreply, assign(socket, :discarding?, false)}

  def handle_event("discard", _params, %{assigns: %{design: %{} = design}} = socket) do
    socket = assign(socket, :discarding?, false)

    case AgentDesigns.discard(socket.assigns.current_scope, design.id) do
      {:ok, _view} ->
        {:noreply,
         socket |> leave() |> reload_helpers() |> put_flash(:info, dgettext("ui", "已放弃对话"))}

      {:error, reason} ->
        {:noreply, socket |> reread() |> put_flash(:error, error_text(reason, nil))}
    end
  end

  def handle_event("new_conversation", _params, socket),
    do: {:noreply, socket |> leave() |> reload_helpers()}

  ## Events: layout (D9)

  def handle_event("tab", %{"tab" => "draft"}, socket),
    do: {:noreply, assign(socket, tab: :draft, draft_dot?: false)}

  def handle_event("tab", _params, socket), do: {:noreply, assign(socket, :tab, :chat)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp seen(form, %{assigns: %{design: %{draft_version: v}}}),
    do: Map.put(form, :draft_version, v)

  defp seen(form, _socket), do: form

  # The result of saving the squad panel (D16): errors as the agent draft panel's.
  defp squad_saved(socket, _form, {:ok, view}),
    do: socket |> assign(:squad_form, nil) |> show(view, false)

  defp squad_saved(socket, form, {:error, {:invalid_squad, %Ecto.Changeset{} = cs}}) do
    form = %{form | errors: %{}, member_errors: %{}, members_error: []}
    assign(socket, :squad_form, SquadForm.put_changeset(form, cs))
  end

  defp squad_saved(socket, form, {:error, :stale}) do
    socket = reread(socket)

    case socket.assigns.design do
      %{status: :open} = fresh ->
        assign(
          socket,
          :squad_form,
          SquadForm.rebase(form, socket.assigns.current_scope, fresh)
        )

      _ ->
        assign(socket, :squad_form, nil)
    end
  end

  defp squad_saved(socket, _form, {:error, :design_closed}),
    do: socket |> assign(:squad_form, nil) |> reread()

  defp squad_saved(socket, form, {:error, :turn_running}),
    do: socket |> assign(:squad_form, form) |> reread()

  defp squad_saved(socket, form, {:error, reason}),
    do: assign(socket, :squad_form, %{form | error: error_text(reason, helper_name(socket))})

  defp kind_param(kind, _current) when kind in ["agent", "squad"], do: kind
  defp kind_param(_kind, current), do: current

  defp started(socket, {:ok, view}, _helper),
    do: socket |> assign(message: "", input_gen: socket.assigns.input_gen + 1) |> enter(view)

  # Another tab started one meanwhile: open it; the input moves to its message box.
  defp started(socket, {:error, {:design_open, id}}, _helper) do
    socket =
      case AgentDesigns.get(socket.assigns.current_scope, id) do
        {:ok, view} -> enter(socket, view)
        _ -> socket
      end

    socket
    |> assign(:input_gen, socket.assigns.input_gen + 1)
    |> put_flash(:info, dgettext("ui", "你已有一个进行中的对话，已为你打开"))
  end

  defp started(socket, {:error, %Ecto.Changeset{} = cs}, _helper),
    do: assign(socket, :start_errors, %{message: message_errors(cs)})

  defp started(socket, {:error, reason}, helper) when reason in [:forbidden, :not_found],
    do: put_flash(socket, :error, error_text(reason, helper))

  defp started(socket, {:error, reason}, helper),
    do: assign(socket, :start_errors, %{helper: [error_text(reason, helper)]})

  # The dialog's on_cancel runs first: the snapshot version comes with the event.
  defp confirm_version(%{version: v}, _param), do: v

  defp confirm_version(nil, param) do
    case Integer.parse(to_string(param)) do
      {v, ""} -> v
      _ -> nil
    end
  end

  defp confirmed(socket, {:ok, %{squad: %{name: name}, agents: agents}}) do
    flash =
      case agents do
        [] -> dgettext("ui", "已创建小队 %{name}", name: name)
        _ -> dgettext("ui", "已创建小队 %{name} 与 %{n} 个 Agent", name: name, n: length(agents))
      end

    socket
    |> put_flash(:info, flash)
    |> push_navigate(to: Url.squad_path(socket.assigns.current_scope.workspace.slug, name))
  end

  defp confirmed(socket, {:ok, %{agents: [agent]}}) do
    slug = socket.assigns.current_scope.workspace.slug

    socket
    |> put_flash(:info, dgettext("ui", "已创建 %{name}", name: agent.name))
    |> push_navigate(to: Url.agent_path(slug, agent.name))
  end

  defp confirmed(socket, {:ok, %{agents: agents}}) do
    socket
    |> put_flash(:info, dgettext("ui", "已创建 %{n} 个 Agent", n: length(agents)))
    |> push_navigate(to: ~p"/w/#{socket.assigns.current_scope.workspace.slug}/agents")
  end

  # The agents' errors (keyed by agent name only) go to their cards; the squad's
  # (D16, `{:invalid_squad, changeset}`) to the squad block.
  defp confirmed(socket, {:error, {:invalid, errors}}) do
    assign(socket,
      invalid: Map.new(errors, fn {name, cs} -> {name, FormErrors.messages(cs)} end),
      squad_invalid: nil
    )
  end

  defp confirmed(socket, {:error, {:invalid_squad, %Ecto.Changeset{} = cs}}),
    do: assign(socket, invalid: nil, squad_invalid: FormErrors.messages(cs))

  defp confirmed(socket, {:error, :stale}),
    do: socket |> reread() |> put_flash(:error, dgettext("ui", "草稿刚被更新，请检查后再确认"))

  defp confirmed(socket, {:error, reason}),
    do: socket |> reread() |> put_flash(:error, error_text(reason, helper_name(socket)))

  defp message_errors(cs), do: Map.get(FormErrors.messages(cs), :message, [])

  defp find_agent(%{assigns: %{design: %{draft: draft}}}, name) when is_binary(name) do
    down = String.downcase(name)
    Enum.find(agents(draft), &(String.downcase(&1["name"] || "") == down))
  end

  defp find_agent(_socket, _name), do: nil

  defp invalid_errors(nil, _name), do: %{}
  defp invalid_errors(invalid, name), do: Map.get(invalid, name, %{})

  defp helper_name(%{assigns: %{design: %{helper: %{name: name}}}}), do: name
  defp helper_name(_socket), do: nil

  ## Messages

  @impl true
  def handle_info({:agent_design, id}, %{assigns: %{design: %{id: id}}} = socket),
    do: {:noreply, reread(socket)}

  def handle_info({:agent_design, _id}, socket), do: {:noreply, socket}

  def handle_info(message, socket)
      when elem(message, 0) in [:agents_changed, :runtimes_changed] do
    socket = socket |> reload_helpers() |> load_lookup()

    socket =
      case socket.assigns.agent_form do
        %{} = form ->
          assign(
            socket,
            :agent_form,
            AgentForm.runtimes_changed(form, socket.assigns.current_scope)
          )

        nil ->
          socket
      end

    socket =
      case {socket.assigns.squad_form, socket.assigns.design} do
        {%{} = form, %{draft: draft}} ->
          assign(
            socket,
            :squad_form,
            SquadForm.refresh(form, socket.assigns.current_scope, draft)
          )

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:provider_accounts_changed}, socket) do
    socket = load_lookup(socket)

    case socket.assigns.agent_form do
      %{} = form ->
        {:noreply,
         assign(
           socket,
           :agent_form,
           AgentForm.accounts_changed(form, socket.assigns.current_scope)
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info(message, %{assigns: %{turn: %{} = turn}} = socket) do
    case AgentDesignTurn.handle_info(message, turn) do
      {:ok, turn} -> {:noreply, assign(socket, :turn, turn)}
      :ignore -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## State for rendering

  defp open?(%{design: %{status: :open}}), do: true
  defp open?(_assigns), do: false

  # Why the draft cannot be edited now (D6), or nil.
  defp locked_reason(%{design: %{status: :open, current_run: nil}}), do: nil

  defp locked_reason(%{design: %{status: :open, helper: helper}}),
    do: dgettext("ui", "等 %{helper} 回复完再修改", helper: helper.name)

  defp locked_reason(%{design: %{}}), do: dgettext("ui", "对话已结束")
  defp locked_reason(_assigns), do: dgettext("ui", "对话已结束")

  defp confirm_reason(%{design: design} = assigns) do
    cond do
      not open?(assigns) ->
        dgettext("ui", "对话已结束")

      design.current_run != nil ->
        dgettext("ui", "等 %{helper} 回复完再确认", helper: design.helper.name)

      AgentDesignSquad.squad?(design) ->
        design.draft
        |> AgentDesignSquad.squad()
        |> AgentDesignSquad.missing()
        |> AgentDesignSquad.missing_text()

      agents(design.draft) == [] ->
        dgettext("ui", "草稿里还没有 Agent")

      true ->
        nil
    end
  end

  # Why the input is unavailable (D4), or nil.
  defp input_reason(%{design: design} = assigns) do
    cond do
      not open?(assigns) -> dgettext("ui", "对话已结束")
      design.current_run != nil -> dgettext("ui", "等 %{helper} 回复完", helper: design.helper.name)
      design.user_messages >= @max_messages -> dgettext("ui", "已达 40 条消息上限，请确认或放弃这个对话")
      true -> nil
    end
  end

  defp helper_items(helpers, scope, current) do
    for h <- helpers, h.name != current do
      item = %{
        id: "design-helper-#{h.name |> String.replace(~r/[^A-Za-z0-9_-]/, "-")}",
        label: h.name,
        description: "#{provider_label(h.provider)} · #{owner_name(h, scope)}",
        on_select: "change_helper",
        value: %{name: h.name}
      }

      case helper_reason(h) do
        nil -> item
        reason -> Map.put(item, :disabled_reason, reason)
      end
    end
  end

  defp highlight_class(%{names: names, version: v}, name) do
    if MapSet.member?(names, name),
      do:
        if(rem(v, 2) == 0,
          do: "motion-safe:animate-draft-ring-a",
          else: "motion-safe:animate-draft-ring-b"
        )
  end

  defp card_errors(nil, _name), do: []

  defp card_errors(invalid, name) do
    for {field, msgs} <- Map.get(invalid, name, %{}), msg <- msgs, do: {field, msg}
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={page_heading(@design)}>
          <:crumb navigate={~p"/w/#{@current_scope.workspace.slug}/agents"}>Agents</:crumb>
        </.page_header>
      </:header>

      <div :if={@forbidden?} id="design-forbidden" class="px-4 py-10">
        <.empty_state
          icon="lucide-messages-square"
          title={dgettext("ui", "只有成员及以上角色能用对话创建 Agent")}
        />
      </div>

      <.start_area
        :if={!@forbidden? and @design == nil}
        helpers={@helpers}
        choice={@helper_choice}
        kind={@kind_choice}
        message={@message}
        gen={@input_gen}
        errors={@start_errors}
        scope={@current_scope}
      />

      <div :if={@design} id="design" class="flex h-full min-h-0 flex-col">
        <nav
          id="design-tabs"
          aria-label={dgettext("ui", "对话创建")}
          class="flex flex-none items-center gap-4 border-b border-border px-4 lg:hidden"
        >
          <button
            id="design-tab-chat"
            type="button"
            phx-click="tab"
            phx-value-tab="chat"
            aria-current={@tab == :chat && "page"}
            class={tab_class(@tab == :chat)}
          >
            {dgettext("ui", "对话")}
          </button>
          <button
            id="design-tab-draft"
            type="button"
            phx-click="tab"
            phx-value-tab="draft"
            aria-current={@tab == :draft && "page"}
            class={tab_class(@tab == :draft)}
          >
            {dgettext("ui", "草稿（%{n}）", n: length(agents(@design.draft)))}
            <span
              :if={@draft_dot?}
              id="design-tab-draft-dot"
              class="size-1.5 rounded-full bg-brand"
              aria-label={dgettext("ui", "有变化")}
            />
          </button>
        </nav>

        <div
          id="design-columns"
          class="grid min-h-0 flex-1 grid-cols-[minmax(0,1fr)] lg:grid-cols-[minmax(0,1fr)_minmax(360px,40%)]"
        >
          <.chat_column
            class={@tab != :chat && "max-lg:hidden"}
            design={@design}
            messages={@streams.messages}
            turn={@turn}
            message={@message}
            gen={@input_gen}
            errors={@message_errors}
            warning={@send_warning}
            input_reason={input_reason(assigns)}
            helper_items={helper_items(@helpers, @current_scope, @design.helper.name)}
            scope={@current_scope}
          />
          <.draft_column
            class={@tab != :draft && "max-lg:hidden"}
            design={@design}
            lookup={@lookup}
            invalid={@invalid}
            squad_invalid={@squad_invalid}
            humans={@humans}
            locked={locked_reason(assigns)}
            confirm_reason={confirm_reason(assigns)}
            highlight={@highlight}
            scope={@current_scope}
          />
        </div>
      </div>

      <AgentForm.panel
        :if={@design}
        form={@agent_form}
        scope={@current_scope}
        on_cancel={JS.push("close_panel")}
        locked={
          @agent_form && @design.current_run &&
            dgettext("ui", "%{helper} 正在回复，回复结束后才能保存", helper: @design.helper.name)
        }
      />

      <SquadForm.panel
        :if={@design}
        form={@squad_form}
        scope={@current_scope}
        on_cancel={JS.push("close_squad_panel")}
        locked={
          @squad_form && @design.current_run &&
            dgettext("ui", "%{helper} 正在回复，回复结束后才能保存", helper: @design.helper.name)
        }
      />

      <.confirm_dialog
        id="design-remove"
        show={@removing != nil}
        title={@removing && dgettext("ui", "从草稿移除 %{name}？", name: @removing)}
        danger
        confirm_label={dgettext("ui", "移除")}
        on_confirm="remove"
        confirm_value={if(@removing, do: %{name: @removing}, else: %{})}
        on_cancel={JS.push("dismiss_remove")}
      >
        {dgettext("ui", "AI 写的配置会一起删除。")}
      </.confirm_dialog>

      <.confirm_dialog
        id="design-confirm"
        show={@confirming != nil}
        title={@confirming && confirm_title(@confirming)}
        confirm_label={dgettext("ui", "创建")}
        on_confirm="confirm"
        confirm_value={if(@confirming, do: %{version: @confirming.version}, else: %{})}
        on_cancel={JS.push("dismiss_confirm")}
      >
        <div :if={@confirming} class="flex flex-col gap-3">
          <.confirm_list
            agents={@confirming.agents}
            squad={@confirming.squad || nil}
            summary={@confirming.summary}
          />
          <p :if={@confirming.squad} class="text-body text-fg-muted" data-squad-note>
            {dgettext("ui", "小队属于工作区，创建后可以在小队页修改成员与说明。")}
          </p>
          <p :if={@confirming.agents != []} class="text-body text-fg-muted">
            {dgettext(
              "ui",
              "它们属于你，运行在你的机器上。环境变量、额外 MCP 服务器、追加参数与指定成员请在创建后到 Agent 的编辑面板设置。"
            )}
          </p>
        </div>
      </.confirm_dialog>

      <.confirm_dialog
        id="design-discard"
        show={@discarding?}
        title={dgettext("ui", "放弃这个对话？")}
        danger
        confirm_label={dgettext("ui", "放弃")}
        on_confirm="discard"
        on_cancel={JS.push("dismiss_discard")}
      >
        {dgettext("ui", "对话记录与草稿都会关闭，草稿里的 Agent 不会创建。")}
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  defp page_heading(design) do
    if AgentDesignSquad.squad?(design),
      do: dgettext("ui", "用对话创建小队"),
      else: dgettext("ui", "用对话创建 Agent")
  end

  defp confirm_title(%{squad: %{} = squad, agents: []}),
    do: dgettext("ui", "创建小队 %{name}？", name: squad["name"])

  defp confirm_title(%{squad: %{} = squad, agents: agents}),
    do: dgettext("ui", "创建小队 %{name} 与 %{n} 个 Agent？", name: squad["name"], n: length(agents))

  defp confirm_title(%{agents: agents}),
    do: dgettext("ui", "创建 %{n} 个 Agent？", n: length(agents))

  defp tab_class(active?) do
    [
      "-mb-px inline-flex h-9 items-center gap-1.5 border-b-2 text-body",
      if(active?,
        do: "border-brand font-medium text-fg",
        else: "border-transparent text-fg-muted"
      )
    ]
  end

  ## Start area (D3)

  attr :helpers, :list, required: true
  attr :choice, :string, default: nil
  attr :kind, :string, default: "agent"
  attr :message, :string, required: true
  attr :gen, :integer, required: true
  attr :errors, :map, required: true
  attr :scope, :map, required: true

  defp start_area(assigns) do
    selected = Enum.find(assigns.helpers, &(&1.name == assigns.choice))

    assigns =
      assign(assigns,
        selected: selected,
        none?: not Enum.any?(assigns.helpers, &(&1.dispatchability == :ok)),
        bytes: byte_size(assigns.message)
      )

    ~H"""
    <div id="design-start" class="mx-auto flex w-full max-w-[720px] flex-col gap-4 px-4 py-8">
      <div>
        <h2 :if={@kind != "squad"} class="text-title font-semibold text-fg">
          {dgettext("ui", "描述你想要的 Agent")}
        </h2>
        <h2 :if={@kind == "squad"} class="text-title font-semibold text-fg">
          {dgettext("ui", "描述你想要的小队")}
        </h2>
        <p :if={@kind != "squad"} class="mt-1 text-body text-fg-muted">
          {dgettext(
            "ui",
            "用你自己的话说：它做什么、怎么工作、用哪个模型都可以。AI 会追问并起草，你确认后才会创建。"
          )}
        </p>
        <p :if={@kind == "squad"} class="mt-1 text-body text-fg-muted">
          {dgettext(
            "ui",
            "用你自己的话说：小队做什么、需要哪些角色、谁来当 leader。AI 会追问并起草小队与它需要的新 Agent，你确认后才会创建。"
          )}
        </p>
      </div>
      <.form
        for={%{}}
        id="design-start-form"
        phx-change="start_change"
        phx-submit="start"
        class="flex flex-col gap-4"
      >
        <.message_box
          id={"design-start-message-#{@gen}"}
          message={@message}
          rows="6"
          placeholder={dgettext("ui", "例如：它负责什么、要遵守哪些约定、想用哪个模型")}
          errors={Map.get(@errors, :message, [])}
        />

        <fieldset id="design-start-kind" class="flex flex-col gap-1">
          <legend class="mb-1 text-label font-medium text-fg">{dgettext("ui", "要创建")}</legend>
          <div class="inline-flex w-fit rounded-field border border-border-strong bg-surface p-0.5">
            <label
              :for={{value, label} <- [{"agent", "Agent"}, {"squad", dgettext("ui", "小队")}]}
              for={"design-start-kind-#{value}"}
              class="inline-flex h-7 cursor-pointer items-center rounded-field px-3 text-body text-fg-muted has-checked:bg-selected has-checked:font-medium has-checked:text-fg has-focus-visible:outline-2 has-focus-visible:outline-offset-2 has-focus-visible:outline-brand"
            >
              <input
                type="radio"
                id={"design-start-kind-#{value}"}
                name="kind"
                value={value}
                checked={@kind == value}
                class="sr-only"
              />
              {label}
            </label>
          </div>
        </fieldset>

        <div class="flex flex-col gap-1">
          <label for="design-start-helper" class="text-label font-medium text-fg">
            {dgettext("ui", "起草 Agent")}
          </label>
          <select
            id="design-start-helper"
            name="helper"
            disabled={@none?}
            class="h-8 w-full rounded-field border border-border-strong bg-surface px-2 text-body text-fg disabled:opacity-60"
          >
            <option
              :for={h <- @helpers}
              value={h.name}
              selected={h.name == @choice}
              disabled={h.dispatchability != :ok}
            >
              {helper_option(h, @scope)}
            </option>
          </select>
          <p
            :for={msg <- Map.get(@errors, :helper, [])}
            id="design-start-helper-error"
            class="text-caption text-danger-fg"
          >
            {msg}
          </p>
          <p :if={@none?} id="design-start-no-helper" class="text-caption text-fg-muted">
            {dgettext("ui", "没有你能触发的托管 Agent。先新建一个 Agent 作为起草 Agent")}
            <.link
              id="design-start-new-agent"
              navigate={~p"/w/#{@scope.workspace.slug}/agents?panel=new-agent"}
              class="ml-1 font-medium text-brand-fg hover:underline"
            >
              {dgettext("ui", "新建 Agent")}
            </.link>
          </p>
        </div>

        <div
          :if={@selected}
          id="design-visibility"
          role="note"
          class="flex flex-col gap-1 rounded-field border border-border bg-surface px-3 py-2 text-caption text-fg-muted"
        >
          <p>
            {visibility_text(@selected, @scope)}{dgettext(
              "ui",
              "它的回复会出现在 %{helper} 的执行记录里，工作区成员都能看到。不要粘贴密钥或密码。",
              helper: @selected.name
            )}
          </p>
          <p>{dgettext("ui", "创建出的 Agent 属于你，运行在你的机器上。")}</p>
        </div>

        <div class="flex justify-end">
          <.button
            id="design-start-submit"
            type="submit"
            variant="primary"
            disabled={@none? or @bytes > max_bytes()}
            phx-disable-with={dgettext("ui", "正在开始…")}
          >
            {dgettext("ui", "开始对话")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp max_bytes, do: @max_bytes

  defp helper_option(h, scope) do
    base = "#{h.name} · #{provider_label(h.provider)} · #{owner_name(h, scope)}"

    case helper_reason(h) do
      nil -> base
      reason -> "#{base}（#{reason}）"
    end
  end

  defp visibility_text(%{owner: %{user_id: id}} = h, %{user: %{id: id}}),
    do: dgettext("ui", "对话会在你的机器上由 %{helper} 处理。", helper: h.name)

  defp visibility_text(h, _scope),
    do: dgettext("ui", "对话会在 %{owner} 的机器上由 %{helper} 处理。", owner: h.owner.name, helper: h.name)

  attr :id, :string, required: true
  attr :message, :string, required: true
  attr :rows, :string, default: "3"
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :errors, :list, default: []
  attr :hint, :string, default: nil

  # The message input with its byte count (D4): Ctrl/⌘+Enter submits (`Editor`),
  # Enter is a new line. Its id carries the input generation, so a sent message leaves
  # a fresh, empty element.
  defp message_box(assigns) do
    assigns = assign(assigns, bytes: byte_size(assigns.message), max: @max_bytes)

    ~H"""
    <div class="flex flex-col gap-1">
      <label for={@id} class="sr-only">{dgettext("ui", "消息")}</label>
      <textarea
        id={@id}
        name="message"
        rows={@rows}
        phx-debounce="300"
        phx-hook="Editor"
        data-submit="mod-enter-form"
        disabled={@disabled}
        placeholder={@placeholder}
        aria-invalid={@errors != [] && "true"}
        class="block max-h-64 w-full resize-y rounded-field border border-border-strong bg-surface px-2 py-1.5 text-body text-fg disabled:opacity-60"
      >{@message}</textarea>
      <div class="flex items-start justify-between gap-2 text-caption">
        <span class="text-fg-muted">{@hint}</span>
        <span
          id={"#{@id}-size"}
          class={[
            "shrink-0 tabular-nums",
            if(@bytes > @max, do: "text-danger-fg", else: "text-fg-muted")
          ]}
          data-over={@bytes > @max && "true"}
        >
          {message_size(@bytes, @max)}
        </span>
      </div>
      <p :for={msg <- @errors} class="text-caption text-danger-fg" data-message-error>{msg}</p>
    </div>
    """
  end

  ## Conversation column (D4, D5, D10)

  attr :class, :any, default: nil
  attr :design, :map, required: true
  attr :messages, :any, required: true
  attr :turn, :map, default: nil
  attr :message, :string, required: true
  attr :gen, :integer, required: true
  attr :errors, :list, required: true
  attr :warning, :string, default: nil
  attr :input_reason, :string, default: nil
  attr :helper_items, :list, required: true
  attr :scope, :map, required: true

  defp chat_column(assigns) do
    helper = assigns.design.helper

    assigns =
      assign(assigns,
        helper: helper,
        helper_warning: helper_reason(helper),
        usage: usage_text(assigns.design.usage),
        bytes: byte_size(assigns.message)
      )

    ~H"""
    <section
      id="design-chat"
      class={["flex min-h-0 min-w-0 flex-col border-border lg:border-r", @class]}
      aria-label={dgettext("ui", "对话")}
    >
      <header class="flex flex-none flex-wrap items-center gap-2 border-b border-border px-4 py-2">
        <span
          id="design-helper"
          class="flex min-w-0 items-center gap-1.5 text-body"
          data-helper={@helper.name}
        >
          <span class="text-fg-muted">{dgettext("ui", "起草：")}</span>
          <.actor_chip actor={%{name: @helper.name, kind: :agent}} />
          <span class="text-caption text-fg-muted">
            {provider_label(@helper.provider)} · {owner_name(@helper, @scope)}
          </span>
          <span
            :if={@helper_warning}
            class="text-warning-fg"
            title={@helper_warning}
            data-helper-warning
          >
            <.icon name="lucide-triangle-alert" class="size-3.5" />
            <span class="sr-only">{@helper_warning}</span>
          </span>
        </span>
        <.dropdown
          :if={@design.status == :open and @design.current_run == nil}
          id="design-helper-menu"
          label={dgettext("ui", "更换起草 Agent")}
          items={@helper_items}
          popover_class="w-72"
        >
          <:trigger>
            <span class="text-caption font-medium text-fg-muted hover:text-fg">{dgettext("ui", "更换")}</span>
          </:trigger>
        </.dropdown>
        <.button
          :if={@design.status == :open and @design.current_run != nil}
          id="design-helper-change-busy"
          size="xs"
          variant="ghost"
          disabled_reason={dgettext("ui", "等这一轮结束后再更换")}
        >
          {dgettext("ui", "更换")}
        </.button>
        <span class="ml-auto flex items-center gap-3 text-caption text-fg-muted">
          <span id="design-count" class="tabular-nums">{@design.user_messages} / 40</span>
          <span :if={@usage} id="design-usage" class="tabular-nums">{@usage}</span>
        </span>
      </header>

      <div class="relative flex min-h-0 flex-1 flex-col">
        <RunLog.follow_list
          id="design-messages"
          jump_id="design-jump"
          class="px-4 py-4"
          list_class="flex flex-col gap-3"
        >
          <li :for={{dom_id, m} <- @messages} id={dom_id} data-seq={m.seq}>
            <.message message={m} helper={@helper} scope={@scope} />
          </li>
          <:tail>
            <AgentDesignTurn.turn :if={@turn} turn={@turn} helper={@helper.name} scope={@scope} />
          </:tail>
        </RunLog.follow_list>
      </div>

      <div class="flex-none border-t border-border px-4 py-3">
        <.closed_note :if={@design.status != :open} design={@design} scope={@scope} />
        <div :if={@design.status == :open} class="flex flex-col gap-2">
          <div
            :if={@warning}
            id="design-send-warning"
            role="alert"
            class="flex flex-wrap items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
          >
            <.icon name="lucide-triangle-alert" class="size-4 shrink-0" />
            <span>{dgettext("ui", "%{helper} 现在不能启动：%{reason}。可以更换起草 Agent",
              helper: @helper.name,
              reason: @warning
            )}</span>
            <.button
              :if={@design.current_run == nil}
              id="design-send-warning-change"
              size="xs"
              phx-click={Menu.open_menu("design-helper-menu")}
            >
              {dgettext("ui", "更换")}
            </.button>
          </div>
          <.form
            for={%{}}
            id="design-send-form"
            phx-change="message_change"
            phx-submit="send"
            class="flex flex-col gap-2"
          >
            <.message_box
              id={"design-message-#{@gen}"}
              message={@message}
              disabled={@input_reason != nil}
              placeholder={@input_reason || dgettext("ui", "继续描述，或回答 AI 的问题")}
              errors={@errors}
              hint={dgettext("ui", "回复会进入 %{helper} 的执行记录，不要粘贴密钥", helper: @helper.name)}
            />
            <div class="flex justify-end">
              <.button
                id="design-send"
                type="submit"
                variant="primary"
                size="sm"
                icon="lucide-send"
                disabled={@input_reason != nil or @bytes > max_bytes() or String.trim(@message) == ""}
                phx-disable-with={dgettext("ui", "正在发送…")}
              >
                {dgettext("ui", "发送")}
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  attr :design, :map, required: true
  attr :scope, :map, required: true

  defp closed_note(assigns) do
    ~H"""
    <div
      id="design-closed"
      role="status"
      data-status={@design.status}
      class="flex flex-wrap items-center gap-2 rounded-field border border-border bg-surface px-3 py-2 text-body text-fg"
    >
      <span :if={@design.status == :confirmed}>
        {dgettext("ui", "这个对话已确认，创建了")}
        <%= for {a, i} <- Enum.with_index(@design.created_agents) do %>
          <span :if={i > 0}>、</span><.link
            navigate={created_path(@design, @scope.workspace.slug, a.name)}
            class="font-mono font-medium text-brand-fg hover:underline"
            data-created
          >{a.name}</.link>
        <% end %>
      </span>
      <span :if={@design.status == :discarded}>{dgettext("ui", "这个对话已放弃")}</span>
      <span :if={@design.status == :expired}>{dgettext("ui", "这个对话 7 天没有活动，已过期")}</span>
      <.button id="design-new" size="sm" class="ml-auto" phx-click="new_conversation">
        {dgettext("ui", "开始新的对话")}
      </.button>
    </div>
    """
  end

  # A squad conversation created its squad too (D16): that name links to the squad page.
  defp created_path(design, slug, name) do
    squad_name = AgentDesignSquad.squad?(design) && AgentDesignSquad.squad(design.draft)["name"]

    if is_binary(squad_name) and String.downcase(squad_name) == String.downcase(name),
      do: Url.squad_path(slug, name),
      else: Url.agent_path(slug, name)
  end

  ## Draft column (D6, D8)

  attr :class, :any, default: nil
  attr :design, :map, required: true
  attr :lookup, :map, required: true
  attr :invalid, :map, default: nil
  attr :squad_invalid, :map, default: nil
  attr :humans, :any, required: true
  attr :locked, :string, default: nil
  attr :confirm_reason, :string, default: nil
  attr :highlight, :map, required: true
  attr :scope, :map, required: true

  defp draft_column(assigns) do
    list = agents(assigns.design.draft)
    squad? = AgentDesignSquad.squad?(assigns.design)

    assigns =
      assign(assigns,
        list: list,
        n: length(list),
        squad?: squad?,
        squad: squad? && AgentDesignSquad.squad(assigns.design.draft),
        pending: edits_text(assigns.design.pending_edits),
        full?: length(list) >= @max_agents
      )

    ~H"""
    <section
      id="design-draft"
      class={["flex min-h-0 min-w-0 flex-col bg-canvas", @class]}
      aria-label={dgettext("ui", "草稿")}
    >
      <header class="flex flex-none items-center gap-2 border-b border-border px-4 py-2">
        <h2 class="text-label font-semibold text-fg">{dgettext("ui", "草稿")}</h2>
        <span id="design-draft-count" class="text-caption tabular-nums text-fg-muted">
          {dgettext("ui", "%{n} / 8 个 Agent", n: @n)}
        </span>
        <.button
          :if={@n > 0}
          id="design-add"
          size="xs"
          variant="ghost"
          icon="lucide-plus"
          class="ml-auto"
          phx-click="add_agent"
          disabled_reason={@locked || if(@full?, do: dgettext("ui", "草稿最多 8 个 Agent"))}
        >
          {dgettext("ui", "添加 Agent")}
        </.button>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto px-4 py-3">
        <div class="flex flex-col gap-3">
          <p
            :if={@pending}
            id="design-pending"
            role="status"
            class="rounded-field border border-info tint-info px-3 py-2 text-caption text-info-fg"
          >
            {dgettext("ui", "这些修改会在你下一条消息时告诉 AI：%{edits}", edits: @pending)}
          </p>
          <p
            :if={@invalid}
            id="design-invalid"
            role="alert"
            class="rounded-field border border-danger tint-danger px-3 py-2 text-caption text-danger-fg"
          >
            {dgettext("ui", "%{n} 个 Agent 未通过校验，没有创建任何 Agent", n: map_size(@invalid))}
          </p>
          <p
            :if={@squad_invalid}
            id="design-squad-invalid"
            role="alert"
            class="rounded-field border border-danger tint-danger px-3 py-2 text-caption text-danger-fg"
          >
            {dgettext("ui", "小队未通过校验，没有创建任何 Agent 与小队")}
          </p>

          <AgentDesignSquad.block
            :if={@squad?}
            design={@design}
            humans={@humans}
            errors={@squad_invalid}
            locked={@locked}
            scope={@scope}
          />

          <div :if={@list == []} id="design-draft-empty">
            <.empty_state
              icon="lucide-bot"
              title={dgettext("ui", "草稿里还没有 Agent")}
              description={
                if(@squad?,
                  do: dgettext("ui", "小队需要的新 Agent 会出现在这里，你也可以直接添加；小队也可以只用工作区已有的成员。"),
                  else: dgettext("ui", "AI 提出的 Agent 会出现在这里。你也可以直接添加。")
                )
              }
            >
              <:action>
                <.button
                  id="design-add-empty"
                  size="sm"
                  icon="lucide-plus"
                  phx-click="add_agent"
                  disabled_reason={@locked}
                >
                  {dgettext("ui", "添加 Agent")}
                </.button>
              </:action>
            </.empty_state>
          </div>

          <.draft_card
            :for={{a, i} <- Enum.with_index(@list)}
            agent={a}
            index={i}
            lookup={@lookup}
            errors={card_errors(@invalid, a["name"])}
            locked={@locked}
            remove_reason={
              if(AgentDesignSquad.references?(@design.draft, a["name"]),
                do: AgentDesignSquad.referenced_text(a["name"])
              )
            }
            highlight={highlight_class(@highlight, a["name"])}
            scope={@scope}
          />
        </div>
      </div>

      <footer
        :if={@design.status == :open}
        class="flex flex-none items-center justify-between gap-2 border-t border-border px-4 py-3"
      >
        <.button id="design-discard-open" size="sm" phx-click="ask_discard">
          {dgettext("ui", "放弃")}
        </.button>
        <.button
          id="design-confirm-open"
          size="sm"
          variant="primary"
          phx-click="ask_confirm"
          disabled_reason={@confirm_reason}
        >
          {confirm_label(@squad?, @squad, @n)}
        </.button>
      </footer>
    </section>
    """
  end

  defp confirm_label(true, squad, 0),
    do: dgettext("ui", "确认创建小队 %{name}", name: AgentDesignSquad.display_name(squad || %{}))

  defp confirm_label(true, squad, n),
    do:
      dngettext(
        "ui",
        "确认创建小队 %{name} 与 %{count} 个 Agent",
        "确认创建小队 %{name} 与 %{count} 个 Agent",
        n,
        name: AgentDesignSquad.display_name(squad || %{})
      )

  defp confirm_label(_squad?, _squad, n),
    do: dngettext("ui", "确认创建 %{count} 个 Agent", "确认创建 %{count} 个 Agent", n)
end
