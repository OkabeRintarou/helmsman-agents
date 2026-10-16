defmodule HelmsmanWeb.McpEditor do
  @moduledoc "A browser-held editor: the server renders only a write-only domain projection."
  use HelmsmanWeb, :html
  alias Helmsman.McpServers.Entry
  alias Helmsman.McpServers.{Import, Templates}

  attr :id, :string, required: true
  attr :config, :map, default: %{}
  attr :name, :string, default: "agent[mcp]"
  attr :provider, :string, default: "claude"
  attr :single, :boolean, default: false

  def editor(assigns) do
    assigns = assign(assigns, :labels, labels()) |> assign(:templates, templates())

    ~H"""
    <div
      id={@id}
      phx-hook="McpEditor"
      phx-update="ignore"
      data-config={Jason.encode!(@config)}
      data-labels={Jason.encode!(@labels)}
      data-templates={Jason.encode!(@templates)}
      data-provider={@provider}
      data-single={to_string(@single)}
      class="flex min-w-0 flex-col gap-3"
    >
      <p class="text-caption text-fg-muted">{dgettext("ui", "不要把密钥写进参数或地址，用本机变量或固定值请求头。")}</p>
      <input type="hidden" name={@name} value="" data-mcp-output />
      <div data-mcp-body class="flex min-w-0 flex-col gap-3"></div>
    </div>
    """
  end

  def validate_reply(params) do
    values = display_values(params["mcp"])

    case Entry.validate(values) do
      {:ok, _} -> %{errors: []}
      {:error, errors} -> %{errors: Enum.map(errors, fn {path, message} -> [path, message] end)}
    end
  end

  defp display_values(%{"$keep" => _} = value) when map_size(value) == 1, do: "••••••"

  defp display_values(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, display_values(v)} end)

  defp display_values(value) when is_list(value), do: Enum.map(value, &display_values/1)
  defp display_values(value), do: value

  def import_reply(params) do
    case Import.parse(params["text"] || "", params["name"] || "imported") do
      {:ok, entries} ->
        %{
          entries:
            Enum.map(entries, fn item ->
              %{
                name: item.name,
                type: Entry.type(item.config),
                config: item.config,
                warnings:
                  Enum.map(item.warnings, &warning/1) ++
                    Enum.map(item.errors, fn {p, m} -> p <> ": " <> m end)
              }
            end)
        }

      _ ->
        %{error: dgettext("ui", "无法识别的格式")}
    end
  end

  defp warning(:default_ignored), do: dgettext("ui", "默认值被忽略")
  defp warning(:input_unsupported), do: dgettext("ui", "输入变量无法表示，请手动填写")

  def templates do
    Enum.map(Templates.all(), fn t -> Map.update!(t, :description, &description/1) end)
  end

  defp description("GitHub（远程）"), do: dgettext("ui", "GitHub（远程）")
  defp description("GitHub（本地容器）"), do: dgettext("ui", "GitHub（本地容器）")
  defp description("Filesystem（请修改目录）"), do: dgettext("ui", "Filesystem（请修改目录）")
  defp description(value), do: value

  defp labels do
    %{
      duplicateName: dgettext("ui", "服务器名不能重复"),
      invalidJson: dgettext("ui", "请输入有效的 JSON 值"),
      setLocal: dgettext("ui", "请在执行机器上设置："),
      add: dgettext("ui", "添加"),
      delete: dgettext("ui", "删除"),
      name: dgettext("ui", "名字"),
      type: dgettext("ui", "类型"),
      template: dgettext("ui", "从模板添加"),
      json: "JSON",
      import: dgettext("ui", "导入"),
      form: dgettext("ui", "表单"),
      preview: dgettext("ui", "预览"),
      command: dgettext("ui", "命令"),
      args: dgettext("ui", "参数（每行一项）"),
      cwd: dgettext("ui", "工作目录"),
      env: dgettext("ui", "环境变量"),
      headers: dgettext("ui", "请求头"),
      key: dgettext("ui", "键"),
      value: dgettext("ui", "值"),
      local: dgettext("ui", "本机变量"),
      fixed: dgettext("ui", "固定值"),
      set: dgettext("ui", "已设置"),
      other: dgettext("ui", "其他字段"),
      url: dgettext("ui", "地址"),
      overwrite: dgettext("ui", "同名服务器已存在，覆盖它？"),
      sse: dgettext("ui", "Codex 不支持 sse，此服务器会被丢弃。")
    }
  end

  attr :summaries, :list, default: []

  def summaries(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div :for={s <- @summaries} class="break-all text-label">
        <code>{s.name}</code>
        <span :if={Map.get(s, :shadowed, false)} class="text-caption text-warning">
          · {dgettext("ui", "与自有服务器同名，未生效")}
        </span>
        <span :if={s.source == "personal"} class="text-caption text-fg-muted"> · {dgettext(
          "ui",
          "个人定义"
        )}</span>
        <%= if Map.has_key?(s, :command) do %>
          <span> · {s.type} · {s.command} {Enum.join(s.args, " ")} {s.url}</span>
          <details :if={s.env != %{} or s.headers != %{}} class="text-caption text-fg-muted">
            <summary>{dgettext("ui", "环境变量与请求头")}</summary>
            <p :for={{k, refs} <- Map.merge(s.env, s.headers)}>
              {k} · {if refs == [],
                do: dgettext("ui", "已设置"),
                else: dgettext("ui", "引用本机 %{names}", names: Enum.join(refs, ", "))}
            </p>
          </details>
        <% end %>
      </div>
    </div>
    """
  end
end
