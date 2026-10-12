defmodule HelmsmanProtocol.Fixtures do
  @moduledoc false

  def machine do
    %{
      "machine_id" => "machine-1",
      "name" => "dev",
      "os" => "linux",
      "arch" => "x86_64",
      "daemon_version" => "0.1.0"
    }
  end

  def cli do
    %{
      "provider" => "claude",
      "version" => "2.0",
      "models" => ["sonnet"],
      "efforts" => ["high"],
      "available" => true,
      "unavailable_reason" => nil
    }
  end

  def join do
    %{
      "protocol" => 1,
      "machine" => machine(),
      "clis" => [cli()],
      "max_concurrency" => 2,
      "active_runs" => [%{"run_id" => 7, "last_seq" => 0}]
    }
  end

  def join_reply do
    %{
      "daemon_id" => 42,
      "runtimes" => [
        %{
          "workspace_id" => 1,
          "workspace_slug" => "team",
          "provider" => "claude",
          "runtime_id" => 2
        }
      ],
      "terminate_run_ids" => [7]
    }
  end

  def repo do
    %{
      "clone_url" => "https://github.com/acme/repo.git",
      "base_branch" => "main",
      "branch" => "hm/T-1",
      "rescue_branches" => [],
      "git_token" => "git-secret",
      "git_token_expires_at" => "2026-10-12T08:00:00Z"
    }
  end

  def run_spec do
    %{
      "run_id" => 7,
      "workspace" => %{"id" => 1, "slug" => "team"},
      "task" => %{"ident" => "T-1", "title" => "Implement"},
      "agent" => %{
        "name" => "coder",
        "provider" => "claude",
        "model" => "sonnet",
        "effort" => "high",
        "custom_args" => ["--verbose"],
        "env" => %{"API_KEY" => "env-secret"},
        "extra_mcp_servers" => %{
          "private" => %{"url" => "https://mcp-secret", "headers" => %{"auth" => "mcp-secret"}}
        }
      },
      "prompt" => "Do the task",
      "resume_session_id" => nil,
      "repo" => repo(),
      "mcp" => %{"url" => "https://example.com/mcp", "token" => "hmr_secret"},
      "limits" => %{"timeout_ms" => 60_000, "idle_timeout_ms" => 10_000},
      "trigger" => %{"kind" => "reopen", "reason" => "merge_conflict", "feedback_id" => 9}
    }
  end

  def usage do
    %{
      "input_tokens" => 1,
      "output_tokens" => 2,
      "cache_read_tokens" => nil,
      "cache_write_tokens" => 0,
      "cost_usd" => 0.01
    }
  end

  def event(type \\ "text", seq \\ 1) do
    data = event_data(type)

    %{"seq" => seq, "type" => type, "data" => data, "at" => "2026-10-12T07:00:00.123456Z"}
  end

  def events, do: %{"run_id" => 7, "events" => [event("text", 3), event("usage", 5)]}

  def finished do
    %{
      "run_id" => 7,
      "status" => "succeeded",
      "failure_reason" => nil,
      "error" => nil,
      "session_id" => "session-1",
      "summary" => "done",
      "usage" => usage()
    }
  end

  def reports do
    %{
      "join" => join(),
      "sync" => Map.drop(join(), ~w(protocol active_runs)),
      "claim" => %{},
      "starting" => %{"run_id" => 7},
      "started" => %{"run_id" => 7, "session_id" => nil},
      "events" => events(),
      "heartbeat" => %{"runs" => [%{"run_id" => 7, "last_seq" => 5}]},
      "steer_ack" => %{"run_id" => 7, "feedback_id" => 9},
      "git_token" => %{"run_id" => 7},
      "pushed" => %{
        "run_id" => 7,
        "branch" => "hm/T-1",
        "base_sha" => "abc",
        "head_sha" => "def",
        "commits" => [%{"sha" => "def", "subject" => "Implement"}],
        "rescue_branch" => nil
      },
      "finished" => finished(),
      "rotate_token" => %{}
    }
  end

  def pushes do
    %{
      "runs_available" => %{},
      "cancel" => %{"run_id" => 7},
      "steer" => %{"run_id" => 7, "feedback_id" => 9, "text" => "Change direction"},
      "config_changed" => %{},
      "revoked" => %{}
    }
  end

  def replies do
    %{
      "join" => join_reply(),
      "sync" => join_reply(),
      "claim" => %{"runs" => [run_spec()]},
      "starting" => %{"action" => "proceed", "reason" => nil},
      "started" => %{},
      "events" => %{"acked_seq" => 5},
      "heartbeat" => %{"terminate_run_ids" => []},
      "steer_ack" => %{},
      "git_token" => %{"token" => "push-secret", "expires_at" => "2026-10-12T08:00:00Z"},
      "pushed" => %{},
      "finished" => %{},
      "rotate_token" => %{"token" => "hmd_secret"}
    }
  end

  defp event_data("text"), do: %{"text" => "你好😀"}
  defp event_data("thinking"), do: %{"text" => "Thinking"}
  defp event_data("tool_call"), do: %{"call_id" => nil, "name" => "read", "input" => "file"}

  defp event_data("tool_result"),
    do: %{"call_id" => nil, "output" => "content", "is_error" => false, "truncated" => false}

  defp event_data("usage"), do: usage()
  defp event_data("session"), do: %{"session_id" => "session-1"}
  defp event_data("result"), do: %{"text" => "done", "success" => true}
  defp event_data("error"), do: %{"reason" => "timeout", "message" => "timed out"}
  defp event_data("status"), do: %{"level" => "info", "message" => "preparing"}
end
