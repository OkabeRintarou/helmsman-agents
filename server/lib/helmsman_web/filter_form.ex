defmodule HelmsmanWeb.FilterForm do
  @moduledoc """
  The save-filter and edit-filter side panel of the BQL page (add-search-query-ui D6):
  `?panel=save-filter` (另存为, the query comes from the editor) and `?panel=edit-filter`
  (rename and, for the owner only, change the visibility).

  The form is a plain map `%{mode: :create | :edit, params, errors, error,
  can_change_visibility?}`; the page calls the domain and gives failures back with
  `put_error/2`. Events: `filter_form_change`, `filter_form_submit` and, for a version
  conflict, `load_latest`.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.FormErrors

  @doc "A new 另存为 form."
  def new(:create) do
    %{
      mode: :create,
      params: %{"name" => "", "visibility" => "private"},
      errors: %{},
      error: nil,
      can_change_visibility?: true
    }
  end

  @doc "An edit form for `filter`."
  def new(:edit, filter, can_change_visibility?) do
    %{
      mode: :edit,
      params: %{"name" => filter.name, "visibility" => to_string(filter.visibility)},
      errors: %{},
      error: nil,
      can_change_visibility?: can_change_visibility?
    }
  end

  @doc "Takes the submitted params (the visibility only when it may change)."
  def change(form, params) when is_map(params) do
    visibility =
      if form.can_change_visibility? and params["visibility"] in ~w(private workspace),
        do: params["visibility"],
        else: form.params["visibility"]

    %{form | params: %{"name" => Map.get(params, "name", ""), "visibility" => visibility}}
  end

  @doc """
  The domain attrs of the form: `name` and `visibility`; an edit by someone who may not
  change the visibility leaves it out.
  """
  def attrs(form) do
    attrs = %{name: String.trim(form.params["name"] || "")}

    if form.can_change_visibility?,
      do: Map.put(attrs, :visibility, String.to_existing_atom(form.params["visibility"])),
      else: attrs
  end

  @doc "Whether the panel holds input that a backdrop click must not discard."
  def dirty?(%{mode: :create, params: params}), do: params["name"] != ""
  def dirty?(_form), do: false

  @doc "Puts a failed save into the form."
  def put_error(form, %Ecto.Changeset{} = changeset) do
    errors = changeset |> FormErrors.messages() |> Map.take([:visibility])

    errors =
      case name_errors(changeset) do
        [] -> errors
        name -> Map.put(errors, :name, name)
      end

    error =
      case Keyword.get_values(changeset.errors, :bql) do
        [{message, opts} | _] -> {:bql, bql_error(message, opts)}
        [] -> if errors == %{}, do: {:message, failure(:invalid)}
      end

    %{form | errors: errors, error: error}
  end

  def put_error(form, :stale), do: %{form | errors: %{}, error: :stale}
  def put_error(form, reason), do: %{form | errors: %{}, error: {:message, failure(reason)}}

  @doc """
  The message and position of a saved filter's `bql` changeset error: the domain
  appends ` (position N)` to the message and puts `position: N` in the opts.
  """
  def bql_error(message, opts) do
    position = Keyword.get(opts, :position)

    message =
      if is_integer(position),
        do: String.replace_suffix(message, " (position #{position})", ""),
        else: message

    %{message: message, position: position}
  end

  defp name_errors(changeset) do
    for {:name, {message, _opts} = error} <- changeset.errors do
      case message do
        "has already been taken" ->
          dgettext("ui", "你已有同名的筛选器")

        "can't be blank" ->
          dgettext("ui", "不能为空")

        "should be at" <> _ ->
          dgettext("ui", "长度须为 1–80 个字符")

        "at most 100 filters per workspace" ->
          failure(:limit_reached)

        _ ->
          %{changeset | errors: [name: error]}
          |> FormErrors.messages()
          |> Map.fetch!(:name)
          |> hd()
      end
    end
  end

  @doc "Text of a failed filter operation."
  def failure(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  def failure(:limit_reached), do: dgettext("ui", "筛选器数量已达上限，请先删除不用的筛选器")
  def failure(:stale), do: dgettext("ui", "这个筛选器刚被修改")
  def failure(_reason), do: dgettext("ui", "操作失败，请稍后重试")

  @doc "The side panel (`form` nil: closed)."
  attr :form, :map, default: nil
  attr :close_path, :string, required: true

  def panel(assigns) do
    ~H"""
    <.side_panel
      id="filter-form-panel"
      show={@form != nil}
      title={title(@form)}
      dirty={@form != nil and dirty?(@form)}
      patch_on_close={@close_path}
      focus="#filter-form-name"
    >
      <:error :if={@form && @form.error}>
        <.icon name="lucide-circle-alert" class="mt-0.5 size-4 flex-none" />
        <div id="filter-form-error" class="flex flex-1 flex-col gap-2">
          <span :if={@form.error == :stale}>{failure(:stale)}</span>
          <.button
            :if={@form.error == :stale}
            id="filter-form-load-latest"
            size="sm"
            phx-click="load_latest"
            class="self-start"
          >
            {dgettext("ui", "载入最新")}
          </.button>
          <span :if={match?({:bql, _}, @form.error)}>{bql_error(@form.error)}</span>
          <span :if={match?({:message, _}, @form.error)}>{elem(@form.error, 1)}</span>
        </div>
      </:error>
      <.form
        :if={@form}
        for={%{}}
        as={:filter}
        id="filter-form"
        phx-change="filter_form_change"
        phx-submit="filter_form_submit"
        class="flex flex-col gap-4"
      >
        <.input
          id="filter-form-name"
          name="filter[name]"
          label={dgettext("ui", "名字")}
          value={@form.params["name"]}
          errors={Map.get(@form.errors, :name, [])}
          maxlength="80"
          autocomplete="off"
        />
        <.input
          :if={@form.can_change_visibility?}
          id="filter-form-visibility"
          name="filter[visibility]"
          type="radio"
          label={dgettext("ui", "可见性")}
          value={@form.params["visibility"]}
          options={visibility_options()}
          errors={Map.get(@form.errors, :visibility, [])}
        />
        <div :if={!@form.can_change_visibility?} id="filter-form-visibility-readonly">
          <span class="text-label font-medium text-fg">{dgettext("ui", "可见性")}</span>
          <p class="text-body text-fg" data-visibility={@form.params["visibility"]}>
            {visibility_label(@form.params["visibility"])}
          </p>
          <p class="text-caption text-fg-muted">{dgettext("ui", "只有所有者能改变可见性")}</p>
        </div>
        <p id="filter-form-sharing" class="text-caption text-fg-muted">
          {dgettext("ui", "共享后工作区所有成员可见、可运行；所有者与管理员可以修改。")}
        </p>
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="filter-form-submit"
            type="submit"
            form="filter-form"
            variant="primary"
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {dgettext("ui", "保存")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp title(%{mode: :edit}), do: dgettext("ui", "编辑筛选器")
  defp title(_form), do: dgettext("ui", "另存为筛选器")

  defp bql_error({:bql, %{message: message, position: position}}) when is_integer(position),
    do: dgettext("ui", "查询无效：第 %{n} 个字符：%{message}", n: position, message: message)

  defp bql_error({:bql, %{message: message}}),
    do: dgettext("ui", "查询无效：%{message}", message: message)

  defp visibility_options do
    [
      {dgettext("ui", "仅自己"), "private"},
      {dgettext("ui", "工作区共享"), "workspace"}
    ]
  end

  defp visibility_label("workspace"), do: dgettext("ui", "工作区共享")
  defp visibility_label(_visibility), do: dgettext("ui", "仅自己")
end
