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
      "vendor" => nil,
      "version" => "2.0",
      "models" => ["sonnet"],
      "efforts" => ["high"],
      "available" => true,
      "unavailable_reason" => nil
    }
  end

  def join do
    %{
      "protocol" => 3,
      "machine" => machine(),
      "clis" => [cli()],
      "max_concurrency" => 2,
      "active_runs" => [%{"run_id" => 7, "last_seq" => 0}],
      "local_repositories" => [local_repository()],
      "repo_registration" => nil
    }
  end

  def local_repository do
    %{
      "name" => "app",
      "path" => "/home/alice/code/app",
      "workspaces" => [1],
      "default_branch" => "main",
      "available" => true,
      "unavailable_reason" => nil
    }
  end

  def watch, do: %{"branch" => "hm/1/t-1", "head_sha" => "abc123", "base_branch" => "main"}

  def reply_local_repository do
    %{"workspace_id" => 1, "name" => "app", "local_repository_id" => 5, "watch" => [watch()]}
  end

  def repo_status do
    %{
      "workspace_id" => 1,
      "name" => "app",
      "results" => [%{"branch" => "hm/1/t-1", "head_sha" => "abc123", "merged" => "yes"}]
    }
  end

  def local_repo do
    %{
      "kind" => "local",
      "mode" => "task",
      "name" => "app",
      "github_repository_id" => nil,
      "clone_url" => nil,
      "base_branch" => "main",
      "branch" => "hm/1/t-1",
      "rescue_branches" => ["hm/1/t-1-run-3"],
      "git_token" => nil,
      "git_token_expires_at" => nil
    }
  end

  @repo_registration ~w(repo_browse repo_register repo_remove repo_browse_result repo_change_result)

  @doc "Wire payload as encoded for an older target version, or :error when not representable."
  def at_version(name, payload, version) do
    cond do
      version >= HelmsmanProtocol.repo_registration_version() ->
        payload

      name in @repo_registration ->
        :error

      name in ["join", "sync"] and payload["repo_registration"] != nil ->
        :error

      name in ["join", "sync"] ->
        at_local_version(name, Map.delete(payload, "repo_registration"), version)

      true ->
        at_local_version(name, payload, version)
    end
  end

  defp at_local_version(name, payload, version) do
    local? = version >= HelmsmanProtocol.local_repositories_version()

    cond do
      local? -> payload
      name == "repo_status" -> :error
      name in ["join", "sync"] and payload["local_repositories"] != nil -> :error
      name in ["join", "sync"] -> Map.delete(payload, "local_repositories")
      true -> payload
    end
  end

  def request_id, do: "AbCdEfGhIjKlMnOpQrStUv"

  def repo_register do
    %{
      "request_id" => request_id(),
      "root" => "~/code",
      "path" => "group/lib",
      "name" => "lib",
      "workspaces" => [7, 9]
    }
  end

  def repo_browse_result do
    %{
      "request_id" => request_id(),
      "error" => nil,
      "message" => nil,
      "roots" => ["~/code", "/srv/git"],
      "repositories" => [
        %{"root" => "~/code", "path" => "app", "name" => "app", "registered_as" => "app"},
        %{"root" => "/srv/git", "path" => ".", "name" => "git", "registered_as" => nil}
      ],
      "truncated" => false
    }
  end

  def repo_change_result do
    %{
      "request_id" => request_id(),
      "action" => "register",
      "name" => "app",
      "error" => nil,
      "message" => nil
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
      "terminate_run_ids" => [7],
      "local_repositories" => [reply_local_repository()]
    }
  end

  def repo do
    %{
      "kind" => "github",
      "mode" => "task",
      "name" => nil,
      "github_repository_id" => 123_456_789,
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
        "provider_account" => nil,
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
      "repo_status" => repo_status(),
      "finished" => finished(),
      "rotate_token" => %{},
      "repo_browse_result" => repo_browse_result(),
      "repo_change_result" => repo_change_result()
    }
  end

  def pushes do
    %{
      "runs_available" => %{},
      "cancel" => %{"run_id" => 7},
      "steer" => %{"run_id" => 7, "feedback_id" => 9, "text" => "Change direction"},
      "config_changed" => %{},
      "revoked" => %{},
      "repo_browse" => %{"request_id" => request_id()},
      "repo_register" => repo_register(),
      "repo_remove" => %{"request_id" => request_id(), "name" => "legacy"}
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
      "repo_status" => %{},
      "finished" => %{},
      "rotate_token" => %{"token" => "hmd_secret"},
      "repo_browse_result" => %{},
      "repo_change_result" => %{}
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
