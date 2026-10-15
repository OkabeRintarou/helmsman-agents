defmodule Helmsman.TaskSpecs.State do
  @moduledoc """
  The mutable state of a spec as a function of its audit events
  (`add-spec-workflow` decision 6). Pure.

  The state is the spec's `change_id`, `latest_version`, `final_version`,
  the proposal, whether it is abandoned and its review requests
  (`%{number => %{version, status, close_reason, review}}`). Every write
  applies the events it appends with `apply_event/2` to the state it read
  under the spec row lock and saves the result, so the rows always equal
  `replay/2` of all the events.

  The status follows from the state: `abandoned` > `finalized` (a final
  version) > `pending_approval` (a proposal) > `in_review` (a `requested`
  request on the latest version) > `draft`.

  An event is a map with `action` (string), `version` (integer or nil),
  `data` (string keys), `actor_id`, `source_run_id` and `inserted_at`.
  """

  @type request :: %{
          version: pos_integer(),
          status: :requested | :submitted | :cancelled | :lapsed,
          close_reason: :superseded | :withdrawn | :abandoned | nil,
          review: pos_integer() | nil
        }
  @type proposal :: %{
          version: pos_integer(),
          summary: String.t(),
          by_id: pos_integer() | nil,
          run_id: pos_integer() | nil,
          at: DateTime.t() | nil
        }
  @type t :: %{
          change_id: String.t() | nil,
          latest_version: non_neg_integer(),
          final_version: pos_integer() | nil,
          proposal: proposal() | nil,
          abandoned: boolean(),
          requests: %{pos_integer() => request()}
        }

  @doc "The state before the first event."
  @spec new() :: t()
  def new,
    do: %{
      change_id: nil,
      latest_version: 0,
      final_version: nil,
      proposal: nil,
      abandoned: false,
      requests: %{}
    }

  @doc "Applies one event."
  @spec apply_event(t(), map()) :: t()
  def apply_event(state, %{action: action} = event), do: apply_action(state, action, event)

  defp apply_action(state, "created", %{data: data}), do: %{state | change_id: data["change_id"]}

  defp apply_action(state, "change_id_changed", %{data: data}),
    do: %{state | change_id: data["to"]}

  defp apply_action(state, "version_submitted", %{version: v}), do: %{state | latest_version: v}

  defp apply_action(state, "review_requested", %{version: v, data: data}) do
    request = %{version: v, status: :requested, close_reason: nil, review: nil}
    put_in(state, [:requests, data["request"]], request)
  end

  defp apply_action(state, "review_request_closed", %{data: data}) do
    update_request(state, data["request"], fn request ->
      %{
        request
        | status: String.to_existing_atom(data["status"]),
          close_reason: data["reason"] && String.to_existing_atom(data["reason"])
      }
    end)
  end

  defp apply_action(state, "review_submitted", %{data: %{"request" => n} = data})
       when is_integer(n),
       do: update_request(state, n, &%{&1 | status: :submitted, review: data["review"]})

  defp apply_action(state, "review_submitted", _event), do: state

  defp apply_action(state, "finalize_proposed", event) do
    proposal = %{
      version: event.version,
      summary: event.data["summary"],
      by_id: event.actor_id,
      run_id: event.source_run_id,
      at: event.inserted_at
    }

    %{state | proposal: proposal}
  end

  defp apply_action(state, action, _event)
       when action in ["proposal_withdrawn", "proposal_rejected"],
       do: %{state | proposal: nil}

  defp apply_action(state, action, %{version: v}) when action in ["approved", "finalized"],
    do: %{state | final_version: v, proposal: nil}

  defp apply_action(state, "abandoned", _event), do: %{state | abandoned: true, proposal: nil}

  defp apply_action(state, "reopened", _event),
    do: %{state | abandoned: false, final_version: nil}

  defp update_request(state, n, fun) do
    case state.requests do
      %{^n => request} -> put_in(state, [:requests, n], fun.(request))
      _none -> state
    end
  end

  @doc "The status of a state; see the module documentation."
  @spec status(t()) :: Helmsman.TaskSpecs.Spec.status()
  def status(state) do
    cond do
      state.abandoned -> :abandoned
      state.final_version -> :finalized
      state.proposal -> :pending_approval
      pending?(state) -> :in_review
      true -> :draft
    end
  end

  defp pending?(state) do
    Enum.any?(state.requests, fn {_n, r} ->
      r.status == :requested and r.version == state.latest_version
    end)
  end

  @doc """
  Replays `events` (in number order) and the issue `notes`
  (`%{review, issue, number, resolution}`, `resolution` nil for a comment):
  `%{spec: %{status, change_id, latest_version, final_version, proposal},
  requests: %{n => request}, issues: %{{review, issue} => resolution}}`.
  An issue without a note that sets a resolution is not listed (`open`).
  """
  @spec replay([map()], [map()]) :: %{spec: map(), requests: map(), issues: map()}
  def replay(events, notes \\ []) do
    state =
      events
      |> Enum.sort_by(& &1[:number])
      |> Enum.reduce(new(), &apply_event(&2, &1))

    issues =
      notes
      |> Enum.filter(& &1.resolution)
      |> Enum.sort_by(&{&1.review, &1.issue, &1.number})
      |> Map.new(&{{&1.review, &1.issue}, &1.resolution})

    %{
      spec: %{
        status: status(state),
        change_id: state.change_id,
        latest_version: state.latest_version,
        final_version: state.final_version,
        proposal: state.proposal
      },
      requests: state.requests,
      issues: issues
    }
  end
end
