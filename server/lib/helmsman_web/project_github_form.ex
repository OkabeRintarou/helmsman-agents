defmodule HelmsmanWeb.ProjectGitHubForm do
  @moduledoc """
  The 仓库与合并 panel of a project (add-github-ui D6; spec web-github 项目的仓库与合并设置).
  The state is a plain map kept by `HelmsmanWeb.TaskLive.Index` (`?panel=project-github`);
  the page owns the events and the background tasks (branch suggestions, saving).

  * `base` holds the project's settings the panel diffs against; `attrs/1` submits only
    the changed keys, so an unchanged base branch is not checked on GitHub again.
  * Repository options: the workspace's available repositories, plus the bound one when
    it is unavailable (it may be kept, not chosen again).
  * Choosing another repository clears the base branch.
  """
  use HelmsmanWeb, :html

  alias Helmsman.GitHub
  alias Helmsman.Projects.Project
  alias HelmsmanWeb.FormErrors

  @keys [
    :repository_id,
    :base_branch,
    :merge_policy,
    :merge_method,
    :require_ci,
    :delete_branch_after_merge
  ]

  ## State

  @doc "A panel for `project` (as read by `Helmsman.Projects`)."
  def new(scope, %Project{} = project) do
    values = values(project)

    %{
      key: project.key,
      base: values,
      params: values,
      current: project.repository,
      repositories: repositories(scope),
      branches: [],
      errors: %{},
      alert: nil,
      saving?: false
    }
  end

  defp values(project) do
    %{
      repository_id: project.repository_id,
      base_branch: project.base_branch || "",
      merge_policy: project.merge_policy,
      merge_method: project.merge_method,
      require_ci: project.require_ci,
      delete_branch_after_merge: project.delete_branch_after_merge
    }
  end

  defp repositories(scope) do
    case GitHub.status(scope) do
      {:ok, %{repositories: repositories}} -> repositories
      {:error, _} -> []
    end
  end

  @doc "Reads the repository options again (`{:github_changed}`, a refused repository)."
  def reload_repositories(form, scope), do: %{form | repositories: repositories(scope)}

  @doc """
  The project changed elsewhere while the panel is open and not saving: the base becomes
  the new settings; fields the user has not changed follow it, changed ones are kept.
  """
  def rebase(form, %Project{} = project) do
    fresh = values(project)

    params =
      Map.new(@keys, fn key ->
        if form.params[key] == form.base[key],
          do: {key, fresh[key]},
          else: {key, form.params[key]}
      end)

    %{form | base: fresh, params: params, current: project.repository}
  end

  @doc """
  The save returned `:stale` and `project` is the re-read one: it becomes the base, and
  the repository and base branch are reset to it (they are what changed); the other
  edits are kept.
  """
  def stale(form, %Project{} = project) do
    fresh = values(project)

    params =
      Map.merge(form.params, Map.take(fresh, [:repository_id, :base_branch]))

    %{form | base: fresh, params: params, current: project.repository, branches: []}
  end

  @doc "Selects the repository `id` (nil = 不绑定); another repository clears the base branch."
  def select_repository(form, id) do
    if id == form.params.repository_id do
      form
    else
      params = %{form.params | repository_id: id, base_branch: ""}
      %{form | params: params, branches: [], errors: Map.drop(form.errors, [:repository_id])}
    end
  end

  @doc "Applies the form's `phx-change` params (fields absent from them keep their value)."
  def change(form, params) when is_map(params) do
    old = form.params.repository_id
    form = select_repository(form, parse_id(params, old))
    p = form.params
    moved? = p.repository_id != old

    params = %{
      p
      | base_branch: if(moved?, do: "", else: Map.get(params, "base_branch", p.base_branch)),
        merge_policy: pick(params["merge_policy"], Project.merge_policies(), p.merge_policy),
        merge_method: pick(params["merge_method"], Project.merge_methods(), p.merge_method),
        require_ci: bool(params["require_ci"], p.require_ci),
        delete_branch_after_merge:
          bool(params["delete_branch_after_merge"], p.delete_branch_after_merge)
    }

    %{form | params: params}
  end

  defp parse_id(params, current) do
    case Map.fetch(params, "repository_id") do
      {:ok, ""} ->
        nil

      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {id, ""} -> id
          _ -> current
        end

      _ ->
        current
    end
  end

  defp pick(value, allowed, current), do: if(value in allowed, do: value, else: current)

  defp bool("true", _current), do: true
  defp bool("false", _current), do: false
  defp bool(_value, current), do: current

  @doc "The changed settings, as `Helmsman.Projects.update_github_settings/3` takes them."
  def attrs(form) do
    for key <- @keys, form.params[key] != form.base[key], into: %{} do
      case {key, form.params[key]} do
        {:base_branch, ""} -> {key, nil}
        {:base_branch, branch} -> {key, String.trim(branch)}
        {key, value} -> {key, value}
      end
    end
  end

  @doc "Whether the panel has unsaved changes."
  def dirty?(form), do: attrs(form) != %{}

  @doc "Marks the save as running and clears the previous errors."
  def saving(form), do: %{form | saving?: true, errors: %{}, alert: nil}

  @doc """
  A failed save. Returns `{:form, form, reload_repositories?}` to keep the panel open, or
  `{:close, message}` (the panel closes with an error flash). `:stale` and a
  `:not_found` that may be the project itself need the page to re-read the project.
  """
  def errors(form, reason), do: error(%{form | saving?: false}, reason)

  defp error(form, {:branch_not_found, branch}),
    do: field(form, :base_branch, dgettext("ui", "GitHub 上没有分支 %{branch}", branch: branch))

  defp error(form, :repository_unavailable) do
    form
    |> field(:repository_id, dgettext("ui", "仓库不可用（安装已断开、已暂停或仓库已移出范围）"))
    |> reload()
  end

  defp error(form, :not_found),
    do: form |> field(:repository_id, dgettext("ui", "仓库不存在")) |> reload()

  defp error(form, :repository_required),
    do: field(form, :base_branch, dgettext("ui", "先选择仓库"))

  defp error(form, {kind, _detail}) when kind in [:github_unavailable, :rate_limited],
    do: alert(form, dgettext("ui", "暂时无法连接 GitHub，设置没有保存，请稍后重试"))

  defp error(form, :stale),
    do: alert(form, dgettext("ui", "仓库或基础分支刚被其他人修改，已载入最新设置，请确认后重新保存"))

  defp error(_form, :forbidden),
    do: {:close, dgettext("ui", "只有工作区的所有者或管理员可以修改仓库设置")}

  defp error(form, %Ecto.Changeset{} = changeset),
    do: {:form, %{form | errors: FormErrors.messages(changeset)}, false}

  defp error(form, _other), do: alert(form, dgettext("ui", "保存失败，请重试"))

  defp alert(form, message), do: {:form, %{form | alert: message}, false}

  defp field(form, key, message), do: {:form, %{form | errors: %{key => [message]}}, false}

  defp reload({:form, form, _reload?}), do: {:form, form, true}

  ## Rendering

  @doc "The repository options: `[%{id, full_name, private, available, default_branch}]`."
  def options(form) do
    available = Enum.filter(form.repositories, & &1.available)
    current_id = form.base.repository_id

    cond do
      current_id == nil or Enum.any?(available, &(&1.id == current_id)) ->
        available

      listed = Enum.find(form.repositories, &(&1.id == current_id)) ->
        [listed | available]

      form.current != nil ->
        [
          %{
            id: current_id,
            full_name: form.current.full_name,
            private: false,
            available: form.current.available,
            default_branch: nil
          }
          | available
        ]

      true ->
        available
    end
  end

  defp selected(form), do: Enum.find(options(form), &(&1.id == form.params.repository_id))

  attr :form, :map, required: true
  attr :project, :map, required: true
  attr :slug, :string, required: true
  attr :close_path, :string, required: true

  def panel(assigns) do
    form = assigns.form
    selected = selected(form)
    no_repo? = form.params.repository_id == nil

    assigns =
      assign(assigns,
        p: form.params,
        options: options(form),
        selected: selected,
        no_repo?: no_repo?,
        no_options?: Enum.all?(form.repositories, &(not &1.available)),
        rebinding?:
          form.base.repository_id != nil and form.params.repository_id != form.base.repository_id,
        default_branch: selected && selected.default_branch,
        changed?: dirty?(form)
      )

    ~H"""
    <.side_panel
      id="project-github"
      show
      title={dgettext("ui", "仓库与合并 · %{key}", key: @project.key)}
      dirty={@changed?}
      patch_on_close={@close_path}
    >
      <:error :if={@form.alert}>
        <.icon name="lucide-circle-alert" class="mt-0.5 size-4 flex-none" />
        <span id="project-github-alert">{@form.alert}</span>
      </:error>
      <.form
        for={%{}}
        as={:project_github}
        id="project-github-form"
        phx-change="project_github_change"
        phx-submit="project_github_save"
        class="flex flex-col gap-6"
      >
        <fieldset disabled={@form.saving?} class="flex flex-col gap-4">
          <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "代码仓库")}</legend>
          <input
            type="hidden"
            id="project-github-repository-id"
            name="project_github[repository_id]"
            value={@p.repository_id || ""}
          />
          <div class="flex flex-col gap-1">
            <span id="project-github-repository-label" class="text-label font-medium text-fg">
              {dgettext("ui", "仓库")}
            </span>
            <.dropdown
              id="project-github-repository"
              label={dgettext("ui", "选择仓库")}
              items={repository_items(@options, @p.repository_id)}
              popover_class="w-80"
              trigger_class="h-8 w-full justify-between border border-border-strong bg-surface px-3"
              class="w-full"
            >
              <:trigger>
                <span class="flex min-w-0 items-center gap-1.5" id="project-github-repository-value">
                  <.icon :if={@selected && @selected.private} name="lucide-lock" class="size-3.5" />
                  <span class="truncate font-mono">
                    {(@selected && @selected.full_name) || dgettext("ui", "不绑定")}
                  </span>
                  <.badge :if={@selected && !@selected.available} tone={:warning}>
                    {dgettext("ui", "不可用")}
                  </.badge>
                </span>
                <.icon name="lucide-chevrons-up-down" class="size-4 text-fg-muted" />
              </:trigger>
            </.dropdown>
            <p
              :for={msg <- Map.get(@form.errors, :repository_id, [])}
              id="project-github-repository-error"
              class="flex items-center gap-1 text-caption text-danger-fg"
            >
              <.icon name="lucide-circle-alert" class="size-3.5" />{msg}
            </p>
            <p
              :if={@no_options?}
              id="project-github-no-repositories"
              class="text-caption text-fg-muted"
            >
              {dgettext("ui", "先在 GitHub 设置中连接 GitHub")}
              <.link
                navigate={"/w/#{@slug}/settings/github"}
                class="text-brand-fg hover:underline"
              >
                {dgettext("ui", "前往 GitHub 设置")}
              </.link>
            </p>
          </div>
          <div
            :if={@rebinding?}
            id="project-github-rebind-warning"
            role="status"
            class="flex items-start gap-2 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
          >
            <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 flex-none" />
            {dgettext(
              "ui",
              "改绑后，原仓库里已开的 PR 不再由 Helmsman 管理（不再转草稿、关闭或合并），需要在 GitHub 上处理；进行中的任务的下一次运行会在新仓库建分支。"
            )}
          </div>
          <.input
            id="project-github-base-branch"
            name="project_github[base_branch]"
            label={dgettext("ui", "基础分支")}
            value={@p.base_branch}
            disabled={@no_repo?}
            list="project-github-branches"
            autocomplete="off"
            placeholder={@default_branch && dgettext("ui", "缺省：%{branch}", branch: @default_branch)}
            help={dgettext("ui", "留空使用仓库的默认分支；保存时会在 GitHub 上确认分支存在")}
            errors={Map.get(@form.errors, :base_branch, [])}
            phx-debounce="200"
            class="font-mono"
          />
          <datalist id="project-github-branches">
            <option :for={branch <- @form.branches} value={branch} />
          </datalist>
        </fieldset>

        <fieldset disabled={@form.saving? or @no_repo?} class="flex flex-col gap-4">
          <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "合并")}</legend>
          <p :if={@no_repo?} id="project-github-merge-disabled" class="text-caption text-fg-muted">
            {dgettext("ui", "绑定仓库后生效")}
          </p>
          <div
            role="radiogroup"
            aria-labelledby="project-github-merge-policy-label"
            class="flex flex-col gap-2"
          >
            <span id="project-github-merge-policy-label" class="text-label font-medium text-fg">
              {dgettext("ui", "合并策略")}
            </span>
            <label
              :for={{value, title, description, recommended?} <- policies()}
              for={"project-github-merge-policy-#{value}"}
              class={[
                "flex cursor-pointer items-start gap-2 rounded-field border px-3 py-2",
                if(@p.merge_policy == value,
                  do: "border-brand bg-selected",
                  else: "border-border hover:bg-hover"
                )
              ]}
            >
              <input
                type="radio"
                id={"project-github-merge-policy-#{value}"}
                name="project_github[merge_policy]"
                value={value}
                checked={@p.merge_policy == value}
                class="radio radio-sm mt-0.5 border-border-strong checked:text-brand"
              />
              <span class="flex min-w-0 flex-col">
                <span class="flex items-center gap-1.5 text-body text-fg">
                  {title}
                  <.badge :if={recommended?} tone={:brand}>{dgettext("ui", "推荐")}</.badge>
                </span>
                <span class="text-caption text-fg-muted">{description}</span>
              </span>
            </label>
          </div>
          <.input
            id="project-github-merge-method"
            name="project_github[merge_method]"
            type="select"
            label={dgettext("ui", "合并方式")}
            value={@p.merge_method}
            options={methods()}
          />
          <.input
            id="project-github-require-ci"
            name="project_github[require_ci]"
            type="checkbox"
            label={dgettext("ui", "要求 CI 通过")}
            checked={@p.require_ci}
            help={dgettext("ui", "没有任何检查时也不合并")}
          />
          <.input
            id="project-github-delete-branch"
            name="project_github[delete_branch_after_merge]"
            type="checkbox"
            label={dgettext("ui", "合并后删除任务分支")}
            checked={@p.delete_branch_after_merge}
          />
        </fieldset>
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="project-github-save"
            type="submit"
            form="project-github-form"
            variant="primary"
            disabled={!@changed? or @form.saving?}
          >
            {if(@form.saving?, do: dgettext("ui", "保存中…"), else: dgettext("ui", "保存"))}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp repository_items(options, selected_id) do
    none = %{
      id: "project-github-repository-none",
      label: dgettext("ui", "不绑定"),
      checked: selected_id == nil,
      on_select: "project_github_repository",
      value: %{id: ""}
    }

    [
      none
      | Enum.map(options, fn repository ->
          %{
            id: "project-github-repository-#{repository.id}",
            label: repository.full_name,
            icon: if(repository.private, do: "lucide-lock"),
            description: if(!repository.available, do: dgettext("ui", "不可用")),
            checked: repository.id == selected_id,
            on_select: "project_github_repository",
            value: %{id: repository.id}
          }
        end)
    ]
  end

  defp policies do
    [
      {"on_verified", dgettext("ui", "验收后自动合并"), dgettext("ui", "人或独立的 Agent 验收后，CI 通过即合并"),
       true},
      {"on_verified_human", dgettext("ui", "只在人验收后自动合并"),
       dgettext("ui", "Agent 验收的需要人在 GitHub 上合并或点立即合并"), false},
      {"manual", dgettext("ui", "不自动合并"), dgettext("ui", "只开 PR，由人合并"), false}
    ]
  end

  defp methods do
    [
      {dgettext("ui", "压缩合并"), "squash"},
      {dgettext("ui", "合并提交"), "merge"},
      {dgettext("ui", "变基合并"), "rebase"}
    ]
  end
end
