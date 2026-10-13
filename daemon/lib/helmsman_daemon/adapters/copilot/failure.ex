defmodule HelmsmanDaemon.Adapters.Copilot.Failure do
  @moduledoc false
  @patterns [
    {~r/No authentication information found|Authentication token found but could not be validated|Authorization error|credentials may be expired/i,
     :provider_auth},
    {~r/run out of .*AI credits|additional usage limit|spending limit for this session/i,
     :provider_quota},
    {~r/rate limit/i, :provider_rate_limit},
    {~r/prompt budget|context window|prompt is too long|exceeds context limit/i,
     :context_overflow},
    {~r/error sending request|Connection refused|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|tunnel error/i,
     :provider_network}
  ]

  def classify(text, spec, fallback) do
    reason =
      Enum.find_value(@patterns, fn {pattern, reason} ->
        if Regex.match?(pattern, text), do: reason
      end)

    cond do
      reason ->
        {:failed, reason, text}

      Regex.match?(~r/No session, task, or name matched/i, text) ->
        {:failed, :cli_error,
         "the Copilot session #{spec.resume_session_id} can no longer be resumed"}

      Regex.match?(~r/from --model flag is not available/i, text) ->
        {:failed, :cli_error,
         "model #{spec.agent.model} is not available to this Copilot account"}

      Regex.match?(~r/Reasoning effort .* is not supported/i, text) ->
        {:failed, :cli_error, text}

      true ->
        {:failed, :cli_error, fallback <> if(text == "", do: "", else: ": " <> text)}
    end
  end

  def session(error, spec) do
    text = error["message"] || "Copilot session error"

    case error["errorType"] do
      type when type in ["authentication", "authorization"] -> {:failed, :provider_auth, text}
      "quota" -> {:failed, :provider_quota, text}
      "rate_limit" -> {:failed, :provider_rate_limit, text}
      "context_limit" -> {:failed, :context_overflow, text}
      _ -> classify(text, spec, text)
    end
  end
end
