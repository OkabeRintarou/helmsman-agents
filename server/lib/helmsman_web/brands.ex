defmodule HelmsmanWeb.Brands do
  @moduledoc """
  Brand icon tables (add-actor-avatars D17): CLI, model vendor and platform keys
  mapped to the vendored lobe-icons names in `priv/static/images/brand/`, plus the
  inference of a model's vendor (`model_vendor/2`) and of a provider account's icon
  from its base URL (`host_icon/2`, delegated to `HelmsmanProtocol.Vendor`).

  Every table is a compile-time constant; the authoritative versions are the
  web-components「品牌图标」「模型名」and web-provider-accounts tables.
  """

  # CLI key => {icon, display name}
  @clis %{
    "claude" => {"claude", "Claude Code"},
    "codex" => {"codex", "Codex"},
    "copilot" => {"githubcopilot", "GitHub Copilot"},
    "cursor" => {"cursor", "Cursor"},
    "gemini" => {"geminicli", "Gemini CLI"},
    "opencode" => {"opencode", "OpenCode"},
    "qoder" => {"qoder", "Qoder"},
    "codebuddy" => {"codebuddy", "CodeBuddy"},
    "trae" => {"trae", "Trae"},
    "kilocode" => {"kilocode", "Kilo Code"},
    "cline" => {"cline", "Cline"},
    "windsurf" => {"windsurf", "Windsurf"}
  }

  @vendors [
    {"anthropic", "Anthropic"},
    {"openai", "OpenAI"},
    {"zai", "Z.ai"},
    {"zhipu", "智谱"},
    {"minimax", "MiniMax"},
    {"qwen", "通义千问"},
    {"bailian", "阿里云百炼"},
    {"moonshot", "月之暗面"},
    {"kimi", "Kimi"},
    {"deepseek", "DeepSeek"},
    {"doubao", "豆包"},
    {"volcengine", "火山引擎"},
    {"gemini", "Gemini"},
    {"google", "Google"},
    {"xai", "xAI"},
    {"grok", "Grok"},
    {"mistral", "Mistral AI"},
    {"hunyuan", "腾讯混元"},
    {"wenxin", "文心"},
    {"baichuan", "百川智能"},
    {"stepfun", "阶跃星辰"},
    {"yi", "Yi"},
    {"zeroone", "零一万物"},
    {"spark", "讯飞星火"},
    {"meta", "Meta"},
    {"cohere", "Cohere"},
    {"perplexity", "Perplexity"}
  ]

  @platforms [
    {"openrouter", "OpenRouter"},
    {"siliconcloud", "硅基流动"},
    {"ollama", "Ollama"},
    {"azure", "Azure"},
    {"bedrock", "Amazon Bedrock"},
    {"vertexai", "Vertex AI"},
    {"groq", "Groq"},
    {"together", "Together AI"},
    {"fireworks", "Fireworks AI"},
    {"huggingface", "Hugging Face"}
  ]

  @vendor_names Map.new(@vendors ++ @platforms)

  @prefixes [
    {"anthropic", ~w(claude sonnet opus haiku)},
    {"openai", ~w(gpt chatgpt codex davinci o1 o3 o4)},
    {"zhipu", ~w(glm chatglm codegeex cogview)},
    {"qwen", ~w(qwen qwq qvq)},
    {"minimax", ~w(minimax abab)},
    {"moonshot", ~w(kimi moonshot)},
    {"deepseek", ~w(deepseek)},
    {"doubao", ~w(doubao)},
    {"gemini", ~w(gemini)},
    {"google", ~w(gemma)},
    {"xai", ~w(grok)},
    {"mistral", ~w(mistral mixtral codestral magistral devstral ministral pixtral)},
    {"hunyuan", ~w(hunyuan)},
    {"wenxin", ~w(ernie)},
    {"baichuan", ~w(baichuan)},
    {"stepfun", ~w(step)},
    {"yi", ~w(yi)},
    {"spark", ~w(spark generalv)},
    {"meta", ~w(llama)},
    {"cohere", ~w(command c4ai)},
    {"perplexity", ~w(sonar)}
  ]

  # Longest prefix first.
  @prefix_list for({vendor, prefixes} <- @prefixes, prefix <- prefixes, do: {prefix, vendor})
               |> Enum.sort_by(fn {prefix, _} -> -byte_size(prefix) end)

  @orgs %{
    "anthropic" => "anthropic",
    "openai" => "openai",
    "google" => "google",
    "meta" => "meta",
    "meta-llama" => "meta",
    "mistralai" => "mistral",
    "x-ai" => "xai",
    "xai" => "xai",
    "moonshotai" => "moonshot",
    "z-ai" => "zai",
    "zai-org" => "zai",
    "thudm" => "zhipu",
    "zhipuai" => "zhipu",
    "deepseek" => "deepseek",
    "deepseek-ai" => "deepseek",
    "qwen" => "qwen",
    "01-ai" => "zeroone",
    "cohere" => "cohere",
    "perplexity" => "perplexity",
    "minimax" => "minimax",
    "minimaxai" => "minimax",
    "baidu" => "wenxin",
    "tencent" => "hunyuan",
    "stepfun-ai" => "stepfun",
    "baichuan-inc" => "baichuan",
    "bytedance" => "doubao"
  }

  @families [~w(zai zhipu), ~w(moonshot kimi), ~w(xai grok), ~w(yi zeroone), ~w(qwen bailian)]

  @doc "The CLI table as `[{key, icon, display name}]`, in key order."
  def clis, do: @clis |> Enum.map(fn {key, {icon, name}} -> {key, icon, name} end) |> Enum.sort()

  @doc "The vendor table as `[{icon, display name}]`, in spec order."
  def vendors, do: @vendors

  @doc "The platform table as `[{icon, display name}]`, in spec order."
  def platforms, do: @platforms

  @doc "Every icon name referenced by the tables (each needs a vendored file)."
  def icon_names do
    Enum.uniq(
      Enum.map(Map.values(@clis), &elem(&1, 0)) ++ Enum.map(@vendors ++ @platforms, &elem(&1, 0))
    )
  end

  @icon_labels Map.new(Map.values(@clis)) |> Map.merge(@vendor_names)

  # CLI icon => CLI key, for the built-in icon search (`copilot` finds `githubcopilot`).
  @cli_keys Map.new(@clis, fn {key, {icon, _name}} -> {icon, key} end)

  @doc """
  Display name of any icon of the tables (a CLI icon gets its CLI's name, e.g.
  `githubcopilot` → 「GitHub Copilot」), nil when unknown.
  """
  @spec icon_label(String.t() | nil) :: String.t() | nil
  def icon_label(icon), do: @icon_labels[key(icon)]

  @doc """
  The built-in avatar icons (update-actor-icons D12) in their three groups
  `[{:cli | :vendor | :platform, [%{icon, name, terms}]}]`, each group ordered by
  display name; `terms` are the lower-case strings the search matches (name, icon and,
  for CLIs, the CLI key).
  """
  def icon_groups do
    cli = Enum.map(@clis, fn {_key, {icon, name}} -> {icon, name} end)

    for {group, list} <- [cli: cli, vendor: @vendors, platform: @platforms] do
      items =
        list
        |> Enum.map(fn {icon, name} ->
          terms = Enum.uniq(Enum.map([name, icon, @cli_keys[icon]], &(&1 && String.downcase(&1))))
          %{icon: icon, name: name, terms: Enum.reject(terms, &is_nil/1)}
        end)
        |> Enum.sort_by(& &1.name)

      {group, items}
    end
  end

  @doc "The icon of an Agent's CLI (`provider`), nil when the CLI is unknown."
  @spec cli_icon(String.t() | atom() | nil) :: String.t() | nil
  def cli_icon(provider), do: with({icon, _} <- @clis[key(provider)], do: icon)

  @doc "Display name of an Agent's CLI, nil when unknown."
  @spec cli_name(String.t() | atom() | nil) :: String.t() | nil
  def cli_name(provider), do: with({_, name} <- @clis[key(provider)], do: name)

  @doc "`key` when it is a vendor or platform icon, otherwise nil."
  @spec vendor_icon(String.t() | nil) :: String.t() | nil
  def vendor_icon(key), do: if(Map.has_key?(@vendor_names, key(key)), do: key(key))

  @doc "Display name of a vendor or platform icon, nil when unknown."
  @spec vendor_name(String.t() | nil) :: String.t() | nil
  def vendor_name(key), do: @vendor_names[key(key)]

  defp key(nil), do: nil
  defp key(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp key(str) when is_binary(str), do: str

  @doc """
  The vendor icon of `model`, or nil: prefix table on the model name (after the last
  `/`), then the organization (the segment before it), then the family override with
  the provider account's icon (`account_icon`).
  """
  @spec model_vendor(String.t() | nil, String.t() | nil) :: String.t() | nil
  def model_vendor(model, account_icon \\ nil)

  def model_vendor(model, account_icon) when is_binary(model) do
    {org, name} =
      case model |> String.trim() |> String.downcase() |> String.split("/") do
        [name] -> {nil, name}
        parts -> {Enum.at(parts, -2), List.last(parts)}
      end

    (by_prefix(name) || @orgs[org]) |> family(account_icon)
  end

  def model_vendor(_model, _account_icon), do: nil

  defp by_prefix(name) do
    Enum.find_value(@prefix_list, fn {prefix, vendor} ->
      size = byte_size(prefix)

      if String.starts_with?(name, prefix) and
           boundary?(binary_part(name, size, byte_size(name) - size)),
         do: vendor
    end)
  end

  defp boundary?(""), do: true
  defp boundary?(<<c, _::binary>>) when c in ?0..?9 or c in [?-, ?_, ?., ?:, ?/], do: true
  defp boundary?(_rest), do: false

  defp family(nil, _account_icon), do: nil

  defp family(vendor, account_icon) do
    if Enum.any?(@families, &(vendor in &1 and account_icon in &1)),
      do: account_icon,
      else: vendor
  end

  @doc """
  The icon inferred for a provider account from its base URL (host suffix table, then
  port 11434 for Ollama) or, without a base URL, from its CLI's official endpoint:
  `HelmsmanProtocol.Vendor.from_base_url/2`, which the daemon shares
  (update-actor-icons D6).
  """
  @spec host_icon(String.t() | nil, String.t() | atom() | nil) :: String.t() | nil
  def host_icon(base_url, cli), do: HelmsmanProtocol.Vendor.from_base_url(base_url, cli)
end
