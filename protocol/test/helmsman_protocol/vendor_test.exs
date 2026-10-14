defmodule HelmsmanProtocol.VendorTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.Vendor

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
  test "all host table rows, subdomains and uppercase hosts" do
    assert length(Vendor.keys()) == 37
    assert Enum.uniq(Vendor.keys()) == Vendor.keys()

    for {host, vendor} <- @hosts do
      for url <- ["https://" <> host, "https://api." <> host <> "/v1", String.upcase(host)] do
        assert Vendor.from_base_url(url, "claude") == vendor
        assert Vendor.valid?(vendor)
      end

      assert Vendor.from_base_url("https://evil" <> host, "claude") == nil
    end

    refute Vendor.valid?(nil)
    refute Vendor.valid?("newco")
    refute Vendor.valid?(:zai)
  end

  test "Bedrock, Ollama port and official defaults retain existing rules" do
    for host <- ~w(bedrock.us-east-1.amazonaws.com bedrock-runtime.cn-north-1.amazonaws.com) do
      assert Vendor.from_base_url("https://" <> host, :claude) == "bedrock"
    end

    assert Vendor.from_base_url("http://10.0.0.5:11434/v1", "codex") == "ollama"
    assert Vendor.from_base_url("https://api.z.ai:11434/v1", "claude") == "zai"

    for blank <- [nil, "", "  "] do
      assert Vendor.from_base_url(blank, "claude") == "anthropic"
      assert Vendor.from_base_url(blank, :codex) == "openai"
      assert Vendor.from_base_url(blank, :cursor) == nil
    end

    assert Vendor.from_base_url("https://llm.corp.example", "claude") == nil
    assert Vendor.from_base_url("https://api.z.ai/api/anthropic", "claude") == "zai"
    assert Vendor.from_base_url("https://open.bigmodel.cn/api/anthropic", "claude") == "zhipu"

    assert Vendor.from_base_url("https://bedrock-runtime.us-east-1.amazonaws.com.evil", nil) ==
             nil
  end
end
