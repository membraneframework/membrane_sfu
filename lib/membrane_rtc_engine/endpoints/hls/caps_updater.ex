defmodule Membrane.RTC.Engine.Endpoint.HLS.CapsUpdater do
  @moduledoc """
    Element responsible for sending caps for specific track to HLS Endpoint and waiting for Endpoint to send updated layout to compositor element.
  """

  use Membrane.Filter

  def_input_pad :input,
    caps: :any,
    demand_unit: :buffers,
    demand_mode: :auto

  def_output_pad :output,
    caps: :any,
    demand_unit: :buffers,
    demand_mode: :auto

  @impl true
  def handle_init(_opts) do
    {:ok, %{update_queue: 0, buffers: %{}}}
  end

  @impl true
  def handle_caps(_pad, caps, _ctx, state) do
    state = put_in(state, [:buffers, state.update_queue + 1], [])

    {{:ok, [forward: caps, notify: {:update_layout, caps}]},
     %{state | update_queue: state.update_queue + 1}}
  end

  @impl true
  def handle_process(_pad, buffer, _ctx, %{update_queue: 0} = state),
    do: {{:ok, buffer: {:output, buffer}}, state}

  @impl true
  def handle_process(_pad, buffer, _ctx, state) do
    new_buffers =
      state
      |> get_in([:buffers, state.update_queue])
      |> then(&[buffer | &1])

    state = put_in(state, [:buffers, state.update_queue], new_buffers)
    {:ok, state}
  end

  @impl true
  def handle_other(:layout_updated, _ctx, state) do
    buffers =
      state
      |> get_in([:buffers, state.update_queue])
      |> Enum.reverse()

    actions = [buffer: {:output, buffers}]

    new_buffers =
      state
      |> Map.get(:buffers)
      |> Map.delete(state.update_queue)

    {{:ok, actions}, %{state | buffers: new_buffers, update_queue: state.update_queue - 1}}
  end
end
