defmodule Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver do
  @moduledoc false

  # TrackReceiver:
  # * generates probe packets on request from the
  # outside (todo)
  # * handles simulcast encoding selection
  # * adjusts RTP packets (sequence numbers, timestamps,
  # VP8 payload headers, etc.)

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.RTC.Engine.Endpoint.WebRTC.{Forwarder, VariantSelector}

  alias Membrane.RTC.Engine.Event.{
    RequestTrackVariant,
    TrackVariantPaused,
    TrackVariantResumed,
    TrackVariantSwitched
  }

  def_options track: [
                type: :struct,
                spec: Membrane.RTC.Engine.Track.t(),
                description: "Track this adapter will maintain"
              ],
              default_variant: [
                spec: Membrane.RTC.Engine.Track.variant(),
                description: "Track variant that will be forwarded by default."
              ]

  def_input_pad :input,
    availability: :always,
    mode: :push,
    caps: Membrane.RTP

  def_output_pad :output,
    availability: :always,
    mode: :push,
    caps: Membrane.RTP

  @impl true
  def handle_init(%__MODULE__{track: track, default_variant: default_variant}) do
    forwarder = Forwarder.new(track.encoding, track.clock_rate)
    selector = VariantSelector.new(track.variants, default_variant)

    state = %{
      track: track,
      forwarder: forwarder,
      selector: selector,
      needs_reconfiguration: false
    }

    {:ok, state}
  end

  @impl true
  def handle_event(_pad, %TrackVariantSwitched{new_variant: new_variant} = event, _ctx, state) do
    Membrane.Logger.debug("Received event: #{inspect(event)}")
    selector = VariantSelector.set_current_variant(state.selector, new_variant)
    actions = [notify: {:variant_switched, new_variant}]
    state = %{state | selector: selector, needs_reconfiguration: true}
    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(_pad, %TrackVariantPaused{variant: variant} = event, _ctx, state) do
    Membrane.Logger.debug("Received event: #{inspect(event)}")
    {selector, next_variant} = VariantSelector.variant_inactive(state.selector, variant)
    actions = maybe_request_track_variant(next_variant)
    state = %{state | selector: selector}
    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(_pad, %TrackVariantResumed{variant: variant} = event, _ctx, state) do
    Membrane.Logger.debug("Received event: #{inspect(event)}")
    {selector, next_variant} = VariantSelector.variant_active(state.selector, variant)
    actions = maybe_request_track_variant(next_variant)
    state = %{state | selector: selector}
    {{:ok, actions}, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_process(_pad, buffer, _ctx, state) do
    forwarder =
      if state.needs_reconfiguration,
        do: Forwarder.reconfigure(state.forwarder, buffer),
        else: state.forwarder

    {forwarder, buffer} = Forwarder.align(forwarder, buffer)
    state = %{state | forwarder: forwarder, needs_reconfiguration: false}
    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_other({:select_variant, variant}, _ctx, state) do
    if variant not in state.selector.all_variants,
      do: raise("Requested variant #{variant} isn't valid")

    {selector, next_variant} = VariantSelector.set_target_variant(state.selector, variant)
    actions = maybe_request_track_variant(next_variant)
    {{:ok, actions}, %{state | selector: selector}}
  end

  @impl true
  def handle_other(msg, ctx, state) do
    super(msg, ctx, state)
  end

  defp maybe_request_track_variant(nil), do: []

  defp maybe_request_track_variant(variant),
    do: [event: {:input, %RequestTrackVariant{variant: variant}}]
end
