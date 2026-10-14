defmodule HelmsmanWeb.Brands do
  @moduledoc """
  Brand icon tables (add-actor-avatars D17): CLI, model vendor and platform keys
  mapped to the vendored lobe-icons names in `priv/static/images/brand/`, plus the
  inference of a model's vendor (`model_vendor/2`) and of a provider account's icon
  from its base URL (`host_icon/2`).

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

  @hosts [
    {"api.anthropic.com", "anthropic"},
    {"api.openai.com", "openai"},
    {"z.ai", "zai"},
    {"bigmodel.cn", "zhipu"},
    {"minimax.chat", "minimax"},
    {"minimaxi.com", "minimax"},
    {"minimax.io", "minimax"},
    {"dashscope.aliyuncs.com", "bailian"},
    {"dashscope-intl.aliyuncs.com", "bailian"},
    {"moonshot.cn", "moonshot"},
    {"moonshot.ai", "moonshot"},
    {"deepseek.com", "deepseek"},
    {"volces.com", "volcengine"},
    {"generativelanguage.googleapis.com", "gemini"},
    {"aiplatform.googleapis.com", "vertexai"},
    {"x.ai", "xai"},
    {"mistral.ai", "mistral"},
    {"hunyuan.cloud.tencent.com", "hunyuan"},
    {"hunyuan.tencentcloudapi.com", "hunyuan"},
    {"baidubce.com", "wenxin"},
    {"baichuan-ai.com", "baichuan"},
    {"stepfun.com", "stepfun"},
    {"lingyiwanwu.com", "zeroone"},
    {"01.ai", "zeroone"},
    {"xf-yun.com", "spark"},
    {"llama.com", "meta"},
    {"cohere.com", "cohere"},
    {"cohere.ai", "cohere"},
    {"perplexity.ai", "perplexity"},
    {"openrouter.ai", "openrouter"},
    {"siliconflow.cn", "siliconcloud"},
    {"siliconflow.com", "siliconcloud"},
    {"openai.azure.com", "azure"},
    {"services.ai.azure.com", "azure"},
    {"cognitiveservices.azure.com", "azure"},
    {"groq.com", "groq"},
    {"together.xyz", "together"},
    {"together.ai", "together"},
    {"fireworks.ai", "fireworks"},
    {"huggingface.co", "huggingface"}
  ]

  @bedrock ~r/^bedrock(?:-runtime)?\.[a-z0-9-]+\.amazonaws\.com$/
  @ollama_port 11_434
  @official %{"claude" => "anthropic", "codex" => "openai"}

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
  port 11434 for Ollama) or, without a base URL, from its CLI's official endpoint.
  """
  @spec host_icon(String.t() | nil, String.t() | atom() | nil) :: String.t() | nil
  def host_icon(base_url, cli) do
    case base_url && String.trim(base_url) do
      blank when blank in [nil, ""] ->
        @official[key(cli)]

      url ->
        uri = parse(url)
        host = uri.host && String.downcase(uri.host)
        by_host(host) || if(uri.port == @ollama_port, do: "ollama")
    end
  end

  defp parse(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) and host != "" -> uri
      _ -> URI.parse("http://" <> url)
    end
  end

  defp by_host(nil), do: nil

  defp by_host(host) do
    Enum.find_value(@hosts, fn {suffix, icon} ->
      if host == suffix or String.ends_with?(host, "." <> suffix), do: icon
    end) || if(Regex.match?(@bedrock, host), do: "bedrock")
  end
end
