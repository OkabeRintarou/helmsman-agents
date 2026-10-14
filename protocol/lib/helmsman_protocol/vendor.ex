defmodule HelmsmanProtocol.Vendor do
  @moduledoc "Shared vendor keys and provider endpoint host inference."

  @keys ~w(anthropic openai zai zhipu minimax qwen bailian moonshot kimi deepseek doubao volcengine gemini google xai grok mistral hunyuan wenxin baichuan stepfun yi zeroone spark meta cohere perplexity openrouter siliconcloud ollama azure bedrock vertexai groq together fireworks huggingface)

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

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec valid?(term()) :: boolean()
  def valid?(value), do: value in @keys

  @spec from_base_url(String.t() | nil, String.t() | atom() | nil) :: String.t() | nil
  def from_base_url(base_url, cli) do
    case base_url && String.trim(base_url) do
      blank when blank in [nil, ""] ->
        @official[key(cli)]

      url ->
        uri = parse(url)
        host = uri.host && String.downcase(uri.host)
        by_host(host) || if(uri.port == @ollama_port, do: "ollama")
    end
  end

  defp key(nil), do: nil
  defp key(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp key(str) when is_binary(str), do: str

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
