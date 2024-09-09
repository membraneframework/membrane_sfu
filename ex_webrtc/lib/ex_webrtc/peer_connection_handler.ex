defmodule Membrane.RTC.Engine.Endpoint.ExWebRTC.PeerConnectionHandler do
  @moduledoc false
  use Membrane.Endpoint

  require Logger

  alias Membrane.Buffer
  alias Membrane.RTC.Engine.Endpoint.ExWebRTC, as: EndpointExWebRTC
  alias Membrane.RTC.Engine.Track

  alias ExWebRTC.{
    ICECandidate,
    MediaStreamTrack,
    PeerConnection,
    RTPReceiver,
    RTPTransceiver,
    SessionDescription
  }

  def_options endpoint_id: [
                spec: String.t(),
                description: "ID of the parent endpoint"
              ],
              ice_port_range: [
                spec: Enumerable.t(non_neg_integer()),
                description: "Range of ports that ICE will use for gathering host candidates."
              ]

  def_input_pad :input,
    accepted_format: _any,
    availability: :on_request

  def_output_pad :output,
    accepted_format: _any,
    availability: :on_request,
    flow_control: :push

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @opts [
    ice_servers: @ice_servers
  ]

  @impl true
  def handle_init(_ctx, opts) do
    %{endpoint_id: endpoint_id} = opts

    pc_options =
      %{ice_port_range: opts.ice_port_range}
      |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
      |> Keyword.merge(@opts)

    {:ok, pc} = PeerConnection.start_link(pc_options)

    state = %{
      pc: pc,
      endpoint_id: endpoint_id,
      # maps engine track_id to rtc track_id
      outbound_tracks: %{},
      # maps rtc track_id to engine track_id
      inbound_tracks: %{},
      stream_id: MediaStreamTrack.generate_stream_id(),
      # TODO: update this map when mid's are reused
      mid_to_track_id: %{}
    }

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, {_track_id, _rid}) = pad, _ctx, state) do
    {[stream_format: {pad, %Membrane.RTP{}}], state}
  end

  @impl true
  def handle_pad_added(_pad, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, engine_track_id), buffer, _ctx, state)
      when is_map_key(state.outbound_tracks, engine_track_id) do
    %Buffer{
      pts: timestamp,
      payload: payload,
      metadata: %{rtp: rtp}
    } = buffer

    track_id = Map.fetch!(state.outbound_tracks, engine_track_id)

    packet =
      ExRTP.Packet.new(
        payload,
        payload_type: rtp.payload_type,
        sequence_number: rtp.sequence_number,
        timestamp: timestamp,
        ssrc: rtp.ssrc,
        csrc: rtp.csrc,
        marker: rtp.marker,
        padding: rtp.padding_size
      )

    extensions = if is_list(rtp.extensions), do: rtp.extensions, else: []

    packet =
      Enum.reduce(extensions, packet, fn extension, packet ->
        ExRTP.Packet.add_extension(packet, extension)
      end)

    :ok = PeerConnection.send_rtp(state.pc, track_id, packet)

    {[], state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, track_id), _buffer, _ctx, state) do
    Logger.warning("Received buffer from unknown track #{track_id}")
    {[], state}
  end

  @impl true
  def handle_parent_notification({:offer, event, outbound_tracks}, _ctx, state) do
    %{"sdpOffer" => offer, "midToTrackId" => mid_to_track_id} = event

    state = update_in(state.mid_to_track_id, &Map.merge(&1, mid_to_track_id))

    new_outbound_tracks =
      Map.filter(outbound_tracks, fn {track_id, _track} ->
        not Map.has_key?(state.outbound_tracks, track_id)
      end)

    offer = SessionDescription.from_json(offer)
    :ok = PeerConnection.set_remote_description(state.pc, offer)

    state = add_new_tracks_to_webrtc(state, new_outbound_tracks)

    {:ok, answer} = PeerConnection.create_answer(state.pc)
    :ok = PeerConnection.set_local_description(state.pc, answer)

    {tracks, state} = receive_new_tracks_from_webrtc(state)

    answer_action = [
      notify_parent: {:answer, SessionDescription.to_json(answer), state.mid_to_track_id}
    ]

    tracks_action = if Enum.empty?(tracks), do: [], else: [notify_parent: {:tracks, tracks}]
    {tracks_removed_actions, state} = get_tracks_removed_actions(state)

    {answer_action ++ tracks_action ++ tracks_removed_actions, state}
  end

  @impl true
  def handle_parent_notification({:candidate, candidate}, _ctx, state) do
    candidate = ICECandidate.from_json(candidate)
    :ok = PeerConnection.add_ice_candidate(state.pc, candidate)

    {[], state}
  end

  def handle_parent_notification({:set_metadata, display_name}, _ctx, state) do
    Logger.metadata(peer: display_name)
    {[], state}
  end

  @impl true
  def handle_parent_notification(_msg, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_event(
        Pad.ref(:output, {engine_track_id, variant}),
        %Membrane.KeyframeRequestEvent{},
        _ctx,
        state
      ) do
    {rtc_track_id, _id} =
      Enum.find(state.inbound_tracks, fn {_rtc_track_id, track_id} ->
        track_id == engine_track_id
      end)

    _rid = EndpointExWebRTC.to_rid(variant)
    PeerConnection.send_pli(state.pc, rtc_track_id, nil)

    {[], state}
  end

  @impl true
  def handle_info({:ex_webrtc, _from, msg}, ctx, state) do
    handle_webrtc_msg(msg, ctx, state)
  end

  defp handle_webrtc_msg({:ice_candidate, candidate}, _ctx, state) do
    msg = {:candidate, ICECandidate.to_json(candidate)}
    {[notify_parent: msg], state}
  end

  defp handle_webrtc_msg({:track, _track}, _ctx, state) do
    raise("We do not expect to receive any tracks")
    {[], state}
  end

  defp handle_webrtc_msg({:rtp, track_id, rid, packet}, ctx, state) do
    rid = if rid == nil, do: :high, else: rid

    actions =
      with {:ok, engine_track_id} <- Map.fetch(state.inbound_tracks, track_id),
           pad <- Pad.ref(:output, {engine_track_id, rid}),
           true <- Map.has_key?(ctx.pads, pad) do
        rtp =
          packet
          |> Map.from_struct()
          |> Map.take([
            :csrc,
            :extensions,
            :marker,
            :padding_size,
            :payload_type,
            :sequence_number,
            :ssrc,
            :timestamp
          ])

        buffer = %Buffer{
          pts: packet.timestamp,
          payload: packet.payload,
          metadata: %{rtp: rtp}
        }

        [buffer: {pad, buffer}]
      else
        _other -> []
      end

    {actions, state}
  end

  defp handle_webrtc_msg({:signaling_state_change, :stable}, _ctx, state) do
    {[notify_parent: :negotiation_done], state}
  end

  defp handle_webrtc_msg({:rtcp, packets}, _ctx, state) do
    actions =
      Enum.flat_map(packets, fn
        # TODO: handle PLI
        {_track_id, %ExRTCP.Packet.PayloadFeedback.PLI{}} -> []
        {_track_id, _other} -> []
      end)

    {actions, state}
  end

  defp handle_webrtc_msg(_msg, _ctx, state) do
    {[], state}
  end

  defp add_new_tracks_to_webrtc(state, new_outbound_tracks) do
    outbound_transceivers =
      state.pc
      |> PeerConnection.get_transceivers()
      |> Enum.filter(fn transceiver ->
        not Map.has_key?(state.mid_to_track_id, transceiver.mid)
      end)

    {new_track_ids, _transceivers} =
      new_outbound_tracks
      |> Enum.flat_map_reduce(
        outbound_transceivers,
        fn {_engine_track_id, engine_track}, outbound_transceivers ->
          add_track(state, engine_track, outbound_transceivers)
        end
      )

    {new_mid_to_track_id, new_outbound_tracks} =
      new_track_ids
      |> Enum.reduce({%{}, %{}}, fn {engine_track_id, track_id, mid}, {mids, tracks} ->
        {Map.put(mids, to_string(mid), engine_track_id),
         Map.put(tracks, engine_track_id, track_id)}
      end)

    state = update_in(state.mid_to_track_id, &Map.merge(&1, new_mid_to_track_id))
    state = update_in(state.outbound_tracks, &Map.merge(&1, new_outbound_tracks))

    state
  end

  defp add_track(state, engine_track, outbound_transceivers) do
    track = MediaStreamTrack.new(engine_track.type, [engine_track.stream_id])

    transceiver =
      Enum.find(outbound_transceivers, fn transceiver ->
        transceiver.kind == track.kind
      end)

    if transceiver do
      PeerConnection.set_transceiver_direction(state.pc, transceiver.id, :sendonly)
      PeerConnection.replace_track(state.pc, transceiver.sender.id, track)

      outbound_transceivers = List.delete(outbound_transceivers, transceiver)

      Logger.info("track #{track.id}, #{track.kind} added on transceiver #{transceiver.id}")

      {[{engine_track.id, track.id, transceiver.mid}], outbound_transceivers}
    else
      Logger.error("Couldn't find transceiver for track #{engine_track.id}")
      {[], outbound_transceivers}
    end
  end

  defp get_tracks_removed_actions(state) do
    transceivers = PeerConnection.get_transceivers(state.pc)

    removed_tracks =
      transceivers
      |> Enum.filter(fn transceiver ->
        transceiver.current_direction == :inactive and
          Map.has_key?(state.inbound_tracks, transceiver.receiver.track.id)
      end)
      |> Enum.map(&Map.get(state.inbound_tracks, &1.receiver.track.id))

    if Enum.empty?(removed_tracks) do
      {[], state}
    else
      inbound_tracks = Map.drop(state.inbound_tracks, removed_tracks)

      {[notify_parent: {:tracks_removed, removed_tracks}],
       %{state | inbound_tracks: inbound_tracks}}
    end
  end

  defp receive_new_tracks_from_webrtc(state) do
    do_receive_new_tracks([]) |> make_tracks(state)
  end

  defp do_receive_new_tracks(acc) do
    receive do
      {:ex_webrtc, pc, {:track, track}} ->
        transceiver =
          PeerConnection.get_transceivers(pc)
          |> Enum.find(fn transceiver ->
            transceiver.receiver.track.id == track.id
          end)

        Logger.info("new track #{track.id}, #{track.kind}")

        PeerConnection.set_transceiver_direction(pc, transceiver.id, :sendrecv)
        PeerConnection.replace_track(pc, transceiver.sender.id, MediaStreamTrack.new(track.kind))
        PeerConnection.set_transceiver_direction(pc, transceiver.id, :recvonly)

        do_receive_new_tracks([track | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp make_tracks(tracks, state) do
    transceivers = PeerConnection.get_transceivers(state.pc)
    do_make_tracks(tracks, transceivers, state, [])
  end

  defp do_make_tracks([], _transceivers, state, acc), do: {Enum.reverse(acc), state}

  defp do_make_tracks([track | tracks], transceivers, state, acc) do
    codec =
      Enum.find_value(transceivers, fn
        %RTPTransceiver{receiver: %RTPReceiver{track: ^track, codec: codec}} -> codec
        _other -> nil
      end)

    %MediaStreamTrack{id: id, kind: kind} = track

    encoding =
      case codec.mime_type do
        "audio/opus" -> :OPUS
        "video/VP8" -> :VP8
        "video/H264" -> :H264
      end

    engine_track =
      Track.new(
        kind,
        state.stream_id,
        state.endpoint_id,
        encoding,
        codec.clock_rate,
        codec.sdp_fmtp_line
      )

    state = update_in(state.inbound_tracks, &Map.put(&1, id, engine_track.id))
    do_make_tracks(tracks, transceivers, state, [engine_track | acc])
  end
end
