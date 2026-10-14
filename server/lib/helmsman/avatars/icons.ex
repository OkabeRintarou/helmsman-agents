defmodule Helmsman.Avatars.Icons do
  @moduledoc """
  The built-in avatar icons (`update-actor-icons` D2): the vendored brand
  icon names (the icon columns of the web-components「品牌图标」tables).
  The domain cannot depend on `HelmsmanWeb.Brands`, so the list is a copy;
  a web test checks that `HelmsmanWeb.Brands.icon_names/0` equals it.
  """

  @keys ~w(
    anthropic azure baichuan bailian bedrock claude cline codebuddy codex cohere
    cursor deepseek doubao fireworks gemini geminicli githubcopilot google grok groq
    huggingface hunyuan kilocode kimi meta minimax mistral moonshot ollama openai
    opencode openrouter perplexity qoder qwen siliconcloud spark stepfun together trae
    vertexai volcengine wenxin windsurf xai yi zai zeroone zhipu
  )

  @key_set MapSet.new(@keys)

  @doc "Every built-in icon key, sorted."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "True when `icon` is a built-in icon key."
  @spec valid?(term()) :: boolean()
  def valid?(icon) when is_binary(icon), do: MapSet.member?(@key_set, icon)
  def valid?(_icon), do: false
end
