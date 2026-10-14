defmodule HelmsmanWeb.BrandsTest do
  @moduledoc """
  `HelmsmanWeb.Brands` row by row against web-components「品牌图标」「模型名」and
  web-provider-accounts「供应商账号的图标选择与显示」(add-actor-avatars D17).
  """
  use ExUnit.Case, async: true

  alias HelmsmanWeb.Brands

  describe "CLI table" do
    for {key, icon, name} <- [
          {"claude", "claude", "Claude Code"},
          {"codex", "codex", "Codex"},
          {"copilot", "githubcopilot", "GitHub Copilot"},
          {"cursor", "cursor", "Cursor"},
          {"gemini", "geminicli", "Gemini CLI"},
          {"opencode", "opencode", "OpenCode"},
          {"qoder", "qoder", "Qoder"},
          {"codebuddy", "codebuddy", "CodeBuddy"},
          {"trae", "trae", "Trae"},
          {"kilocode", "kilocode", "Kilo Code"},
          {"cline", "cline", "Cline"},
          {"windsurf", "windsurf", "Windsurf"}
        ] do
      test "#{key}" do
        assert Brands.cli_icon(unquote(key)) == unquote(icon)
        assert Brands.cli_name(unquote(key)) == unquote(name)
      end
    end

    test "atoms work and unknown CLIs have no icon" do
      assert Brands.cli_icon(:codex) == "codex"
      assert Brands.cli_icon("bar") == nil
      assert Brands.cli_name(nil) == nil
      assert length(Brands.clis()) == 12
    end
  end

  test "vendor and platform tables" do
    vendors =
      ~w(anthropic openai zai zhipu minimax qwen bailian moonshot kimi deepseek doubao volcengine
         gemini google xai grok mistral hunyuan wenxin baichuan stepfun yi zeroone spark meta cohere
         perplexity)

    platforms =
      ~w(openrouter siliconcloud ollama azure bedrock vertexai groq together fireworks huggingface)

    assert Enum.map(Brands.vendors(), &elem(&1, 0)) == vendors
    assert Enum.map(Brands.platforms(), &elem(&1, 0)) == platforms
    assert Brands.vendor_name("zhipu") == "智谱"
    assert Brands.vendor_name("siliconcloud") == "硅基流动"
    assert Brands.vendor_icon("foo") == nil
    assert Brands.vendor_icon("bedrock") == "bedrock"
  end

  describe "model_vendor/2" do
    for {model, vendor} <- [
          # spec scenario 常见模型
          {"claude-sonnet-4-5", "anthropic"},
          {"gpt-5.1-codex", "openai"},
          {"o3", "openai"},
          {"glm-5.3", "zhipu"},
          {"qwen3-coder-plus", "qwen"},
          {"MiniMax-M2", "minimax"},
          {"kimi-k2", "moonshot"},
          {"deepseek-v3.2", "deepseek"},
          {"gemini-2.5-pro", "gemini"},
          # every prefix of the table
          {"sonnet", "anthropic"},
          {"opus-4", "anthropic"},
          {"haiku-3.5", "anthropic"},
          {"chatgpt-4o-latest", "openai"},
          {"codex-mini", "openai"},
          {"davinci-002", "openai"},
          {"o1-mini", "openai"},
          {"o4-mini", "openai"},
          {"chatglm3-6b", "zhipu"},
          {"codegeex-4", "zhipu"},
          {"cogview-3", "zhipu"},
          {"qwq-32b", "qwen"},
          {"qvq-max", "qwen"},
          {"abab6.5s", "minimax"},
          {"moonshot-v1-8k", "moonshot"},
          {"doubao-pro-32k", "doubao"},
          {"gemma-3", "google"},
          {"grok-4", "xai"},
          {"mistral-large", "mistral"},
          {"mixtral-8x7b", "mistral"},
          {"codestral-latest", "mistral"},
          {"magistral-medium", "mistral"},
          {"devstral-small", "mistral"},
          {"ministral-8b", "mistral"},
          {"pixtral-12b", "mistral"},
          {"hunyuan-turbo", "hunyuan"},
          {"ernie-4.0", "wenxin"},
          {"baichuan4", "baichuan"},
          {"step-2", "stepfun"},
          {"yi-large", "yi"},
          {"spark-max", "spark"},
          {"generalv3.5", "spark"},
          {"llama-3.1", "meta"},
          {"command-r", "cohere"},
          {"c4ai-aya", "cohere"},
          {"sonar-pro", "perplexity"},
          {"glm_4", "zhipu"},
          {"qwen:7b", "qwen"},
          {"  Claude-Opus-4  ", "anthropic"},
          # spec scenario 带组织前缀
          {"meta-llama/llama-4-maverick", "meta"},
          {"x-ai/foo-1", "xai"},
          # organization aliases
          {"anthropic/x", "anthropic"},
          {"openai/x", "openai"},
          {"google/x", "google"},
          {"meta/x", "meta"},
          {"mistralai/x", "mistral"},
          {"xai/x", "xai"},
          {"moonshotai/x", "moonshot"},
          {"z-ai/x", "zai"},
          {"zai-org/x", "zai"},
          {"thudm/x", "zhipu"},
          {"zhipuai/x", "zhipu"},
          {"deepseek/x", "deepseek"},
          {"deepseek-ai/x", "deepseek"},
          {"qwen/x", "qwen"},
          {"01-ai/x", "zeroone"},
          {"cohere/x", "cohere"},
          {"perplexity/x", "perplexity"},
          {"minimax/x", "minimax"},
          {"minimaxai/x", "minimax"},
          {"baidu/x", "wenxin"},
          {"tencent/x", "hunyuan"},
          {"stepfun-ai/x", "stepfun"},
          {"baichuan-inc/x", "baichuan"},
          {"bytedance/x", "doubao"},
          {"openrouter/z-ai/x", "zai"},
          # spec scenario 前缀边界 / 未知模型
          {"commander-x", nil},
          {"stepwise-1", nil},
          {"my-finetune-7b", nil},
          {"", nil}
        ] do
      test "#{inspect(model)} -> #{inspect(vendor)}" do
        assert Brands.model_vendor(unquote(model)) == unquote(vendor)
      end
    end

    test "family override with the account's icon (spec 同族覆盖)" do
      assert Brands.model_vendor("glm-5.3", "zai") == "zai"
      assert Brands.model_vendor("glm-5.3") == "zhipu"
      assert Brands.model_vendor("z-ai/x", "zhipu") == "zhipu"
      assert Brands.model_vendor("kimi-k2", "kimi") == "kimi"
      assert Brands.model_vendor("grok-4", "grok") == "grok"
      assert Brands.model_vendor("yi-large", "zeroone") == "zeroone"
      assert Brands.model_vendor("qwen3", "bailian") == "bailian"
      assert Brands.model_vendor("glm-5.3", "openrouter") == "zhipu"
      assert Brands.model_vendor(nil, "zai") == nil
    end
  end

  describe "host_icon/2" do
    for {url, icon} <- [
          {"https://api.anthropic.com", "anthropic"},
          {"https://api.openai.com/v1", "openai"},
          {"https://api.z.ai/api/anthropic", "zai"},
          {"https://open.bigmodel.cn/api/paas/v4", "zhipu"},
          {"https://api.minimax.chat/v1", "minimax"},
          {"https://api.minimaxi.com/anthropic", "minimax"},
          {"https://api.minimax.io", "minimax"},
          {"https://dashscope.aliyuncs.com/compatible-mode/v1", "bailian"},
          {"https://dashscope-intl.aliyuncs.com", "bailian"},
          {"https://api.moonshot.cn/anthropic", "moonshot"},
          {"https://api.moonshot.ai", "moonshot"},
          {"https://api.deepseek.com/anthropic", "deepseek"},
          {"https://ark.cn-beijing.volces.com/api/v3", "volcengine"},
          {"https://generativelanguage.googleapis.com", "gemini"},
          {"https://aiplatform.googleapis.com", "vertexai"},
          {"https://api.x.ai/v1", "xai"},
          {"https://api.mistral.ai", "mistral"},
          {"https://api.hunyuan.cloud.tencent.com/v1", "hunyuan"},
          {"https://hunyuan.tencentcloudapi.com", "hunyuan"},
          {"https://qianfan.baidubce.com/v2", "wenxin"},
          {"https://api.baichuan-ai.com", "baichuan"},
          {"https://api.stepfun.com", "stepfun"},
          {"https://api.lingyiwanwu.com", "zeroone"},
          {"https://api.01.ai", "zeroone"},
          {"https://spark-api-open.xf-yun.com", "spark"},
          {"https://api.llama.com", "meta"},
          {"https://api.cohere.com", "cohere"},
          {"https://api.cohere.ai", "cohere"},
          {"https://api.perplexity.ai", "perplexity"},
          {"https://openrouter.ai/api/v1", "openrouter"},
          {"https://api.siliconflow.cn/v1", "siliconcloud"},
          {"https://api.siliconflow.com", "siliconcloud"},
          {"https://acme.openai.azure.com", "azure"},
          {"https://acme.services.ai.azure.com", "azure"},
          {"https://acme.cognitiveservices.azure.com", "azure"},
          {"https://bedrock-runtime.us-east-1.amazonaws.com", "bedrock"},
          {"https://bedrock.eu-west-1.amazonaws.com", "bedrock"},
          {"https://api.groq.com/openai/v1", "groq"},
          {"https://api.together.xyz", "together"},
          {"https://api.together.ai", "together"},
          {"https://api.fireworks.ai/inference", "fireworks"},
          {"https://router.huggingface.co", "huggingface"},
          {"HTTPS://API.Z.AI", "zai"},
          {"http://localhost:11434/v1", "ollama"},
          {"http://192.168.1.5:11434", "ollama"},
          {"https://llm.internal.corp/v1", nil},
          {"https://my-proxy.example.com/v1", nil},
          # suffix boundary: "notz.ai" does not end with ".z.ai"
          {"https://notz.ai", nil},
          {"https://s3.us-east-1.amazonaws.com", nil},
          {"api.deepseek.com", "deepseek"}
        ] do
      test "#{url}" do
        assert Brands.host_icon(unquote(url), "claude") == unquote(icon)
      end
    end

    test "an empty base URL uses the CLI's official endpoint" do
      assert Brands.host_icon(nil, "claude") == "anthropic"
      assert Brands.host_icon("", "codex") == "openai"
      assert Brands.host_icon("  ", :codex) == "openai"
      assert Brands.host_icon(nil, "copilot") == nil
    end
  end

  # update-actor-icons 4.6: the protocol's vendor keys are exactly the icons of the
  # vendor and platform tables.
  test "HelmsmanProtocol.Vendor.keys/0 is the vendor and platform keys" do
    keys = Enum.map(Brands.vendors() ++ Brands.platforms(), &elem(&1, 0))
    assert Enum.sort(HelmsmanProtocol.Vendor.keys()) == Enum.sort(keys)
    assert length(HelmsmanProtocol.Vendor.keys()) == length(keys)
  end
end
