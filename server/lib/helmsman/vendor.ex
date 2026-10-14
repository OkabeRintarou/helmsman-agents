defmodule Helmsman.Vendor do
  @moduledoc """
  PLACEHOLDER(update-actor-icons): stands in for `HelmsmanProtocol.Vendor`
  (design D6, group 1) until the protocol library has it. When the module
  is loaded every call goes to it; until then `valid?/1` checks the vendor
  and platform keys and `from_base_url/2` infers nothing. Once group 1 is
  merged, callers use `HelmsmanProtocol.Vendor` and this module goes away.
  """

  @keys MapSet.new(~w(
    anthropic azure baichuan bailian bedrock cohere deepseek doubao fireworks gemini
    google grok groq huggingface hunyuan kimi meta minimax mistral moonshot ollama
    openai openrouter perplexity qwen siliconcloud spark stepfun together vertexai
    volcengine wenxin xai yi zai zeroone zhipu
  ))

  @doc "True when `key` is a known vendor or platform key."
  @spec valid?(term()) :: boolean()
  def valid?(key) do
    if protocol?(), do: protocol().valid?(key), else: MapSet.member?(@keys, key)
  end

  @doc "The vendor key inferred from a provider account's base URL and CLI, or nil."
  @spec from_base_url(String.t() | nil, String.t() | atom() | nil) :: String.t() | nil
  def from_base_url(base_url, cli) do
    if protocol?(), do: protocol().from_base_url(base_url, cli)
  end

  @doc "True once the protocol library provides `HelmsmanProtocol.Vendor`."
  @spec protocol?() :: boolean()
  def protocol?, do: Code.ensure_loaded?(protocol())

  # Resolved at run time so that neither the compiler nor Dialyzer looks
  # for the module before it exists.
  defp protocol, do: Module.concat(["HelmsmanProtocol", "Vendor"])
end
