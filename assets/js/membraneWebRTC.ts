import {
  MediaEvent,
  SerializedMediaEvent,
  deserializeMediaEvent,
  generateMediaEvent,
  generateCustomEvent,
  serializeMediaEvent,
} from "./mediaEvent";
import { v4 as uuidv4 } from "uuid";

/**
 * Interface describing Peer.
 */
export interface Peer {
  /**
   * Peer's id. It is assigned by user in custom logic that use backend API.
   */
  id: string;
  /**
   * Any information that was provided in {@link join}.
   */
  metadata: any;
  /**
   * Mapping between track's id (generated by rtc engine) and its metadata. Track metadata
   * can be set using {@link addTrack}. Track id is generated by RTC engine.
   */
  trackIdToMetadata: Map<string, any>;
}

/**
 * Config passed to {@link MembraneWebRTC}.
 */
export interface MembraneWebRTCConfig {
  callbacks: Callbacks;
  rtcConfig?: RTCConfiguration;
  /**
   * Determines wheater user want to receive media from other peers.
   */
  receiveMedia?: boolean;
}

/**
 * Track's context i.e. all data that can be usful when operating on track.
 */
export interface TrackContext {
  track: MediaStreamTrack | null;
  /**
   * Stream this track belongs to.
   */
  stream: MediaStream | null;
  /**
   * Peer this track comes from.
   */
  peer: Peer;
  /**
   * Track id. It is generated by RTC engine and takes form `peer_id:<random_uuidv4>`.
   * It is WebRTC agnostic i.e. it does not contain `mid` or `stream id`.
   */
  trackId: string;
  /**
   * Any info that was passed in {@link addTrack}.
   */
  metadata: any;
}

/**
 * Callbacks that has to be implemented by user.
 */
export interface Callbacks {
  /**
   * Called each time MembraneWebRTC need to send some data to the server.
   */
  onSendMediaEvent: (mediaEvent: SerializedMediaEvent) => void;

  /**
   * Called when peer was accepted. Triggered by {@link join}
   */
  onJoinSuccess?: (peerId: string, peersInRoom: [Peer]) => void;
  /**
   * Called when peer was not accepted. Triggered by {@link join}
   * @param metadata - Passthru for client application to communicate further actions to frontend
   */
  onJoinError?: (metadata: any) => void;

  /**
   * Called when data in a new track arrives.
   *
   * This callback is always called after {@link onTrackAdded}.
   * It informs user that data related to the given track arrives and can be played or displayed.
   */
  onTrackReady?: (ctx: TrackContext) => void;
  /**
   * Called each time the peer which was already in the room, adds new track. Fields track and stream will be set to null.
   * These fields will be set to non-null value in {@link onTrackReady}
   */
  onTrackAdded?: (ctx: TrackContext) => void;
  /**
   * Called when some track will no longer be sent.
   *
   * It will also be called before {@link onPeerLeft} for each track of this peer.
   */
  onTrackRemoved?: (ctx: TrackContext) => void;
  /**
   * Called each time peer has its track metadata updated.
   */
  onTrackUpdated?: (ctx: TrackContext) => void;
  /**
   * Called each time new peer joins the room.
   */
  onPeerJoined?: (peer: Peer) => void;
  /**
   * Called each time peer leaves the room.
   */
  onPeerLeft?: (peer: Peer) => void;
  /**
   * Called each time peer has its metadata updated.
   */
  onPeerUpdated?: (peer: Peer) => void;

  /**
   * Called in case of errors related to multimedia session e.g. ICE connection.
   */
  onConnectionError?: (message: string) => void;
}

/**
 * Main class that is responsible for connecting to the SFU server, sending and receiving media.
 */
export class MembraneWebRTC {
  private receiveMedia: boolean;

  private localTracksWithStreams: {
    track: MediaStreamTrack;
    stream: MediaStream;
  }[] = [];
  private trackIdToTrack: Map<string, TrackContext> = new Map();
  private connection?: RTCPeerConnection;
  private idToPeer: Map<String, Peer> = new Map();
  private localPeer: Peer = { id: "", metadata: {}, trackIdToMetadata: new Map() };
  private localTrackIdToTrack: Map<string, TrackContext> = new Map();
  private midToTrackId: Map<string, string> = new Map();
  private rtcConfig: RTCConfiguration = {
    iceServers: [
      {
        urls: "stun:stun.l.google.com:19302",
      },
    ],
  };

  private readonly callbacks: Callbacks;

  constructor(config: MembraneWebRTCConfig) {
    const { receiveMedia = true, callbacks, rtcConfig } = config;

    this.receiveMedia = receiveMedia;

    this.callbacks = callbacks;
    this.rtcConfig = rtcConfig || this.rtcConfig;
  }

  /**
   * Tries to join to the SFU server. If user is accepted then {@link onJoinSuccess}
   * will be called. In other case {@link onJoinError} is invoked.
   *
   * @param peerMetadata - Any information that other peers will receive in {@link onPeerJoined}
   * after accepting this peer
   *
   * @example
   * ```ts
   * let webrtc = new MembraneWebRTC(...)
   * webrtc.join({displayName: "Bob"})
   * ```
   */
  public join = (peerMetadata: any): void => {
    try {
      this.localPeer.metadata = peerMetadata;
      let mediaEvent = generateMediaEvent("join", {
        receiveMedia: this.receiveMedia,
        metadata: peerMetadata,
      });
      this.sendMediaEvent(mediaEvent);
    } catch (e: any) {
      this.callbacks.onConnectionError?.(e);
      this.leave();
    }
  };
  /**
   * Feeds media event received from SFU server to {@link MembraneWebRTC}.
   * This function should be called whenever some media event from SFU server
   * was received and can result in {@link MembraneWebRTC} generating some other
   * media events.
   *
   * @param mediaEvent - String data received over custom signalling layer.
   *
   * @example
   * This example assumes pheonix channels as signalling layer.
   * As pheonix channels require objects, SFU server encapsulates binary data into
   * map with one field that is converted to object with one field on the TS side.
   * ```ts
   * webrtcChannel.on("mediaEvent", (event) => webrtc.receiveMediaEvent(event.data));
   * ```
   */
  public receiveMediaEvent = (mediaEvent: SerializedMediaEvent) => {
    const deserializedMediaEvent = deserializeMediaEvent(mediaEvent);
    switch (deserializedMediaEvent.type) {
      case "peerAccepted":
        this.localPeer.id = deserializedMediaEvent.data.id;
        this.callbacks.onJoinSuccess?.(
          deserializedMediaEvent.data.id,
          deserializedMediaEvent.data.peersInRoom
        );

        let peers = deserializedMediaEvent.data.peersInRoom as Peer[];
        peers.forEach((peer) => {
          this.addPeer(peer);
        });
        break;

      case "peerDenied":
        this.callbacks.onJoinError?.(deserializedMediaEvent.data);
        break;

      default:
        if (this.localPeer.id != null) this.handleMediaEvent(deserializedMediaEvent);
    }
  };

  private handleMediaEvent = (deserializedMediaEvent: MediaEvent) => {
    let peer: Peer;
    let data;
    switch (deserializedMediaEvent.type) {
      case "offerData":
        const turnServers = deserializedMediaEvent.data.integratedTurnServers;
        const icePolicy = deserializedMediaEvent.data.iceTransportPolicy;
        this.setTurns(turnServers, icePolicy);

        const offerData = new Map<string, number>(
          Object.entries(deserializedMediaEvent.data.tracksTypes)
        );

        this.onOfferData(offerData);
        break;

      case "tracksAdded":
        data = deserializedMediaEvent.data;
        if (this.getPeerId() === data.peerId) return;
        data.trackIdToMetadata = new Map<string, any>(Object.entries(data.trackIdToMetadata));
        peer = this.idToPeer.get(data.peerId)!;
        const oldTrackIdToMetadata = peer.trackIdToMetadata;
        peer.trackIdToMetadata = new Map([...peer.trackIdToMetadata, ...data.trackIdToMetadata]);
        this.idToPeer.set(peer.id, peer);
        Array.from(peer.trackIdToMetadata.entries()).forEach(([trackId, metadata]) => {
          if (!oldTrackIdToMetadata.has(trackId)) {
            const ctx = {
              stream: null,
              track: null,
              trackId,
              metadata,
              peer,
            };
            this.trackIdToTrack.set(trackId, ctx);
            this.callbacks.onTrackAdded?.(ctx);
          }
        });
        break;
      case "tracksRemoved":
        data = deserializedMediaEvent.data;
        const peerId = data.peerId;
        if (this.getPeerId() === data.peerId) return;
        const trackIds = data.trackIds as string[];
        trackIds.forEach((trackId) => {
          const trackContext = this.trackIdToTrack.get(trackId)!;
          this.callbacks.onTrackRemoved?.(trackContext);
          this.eraseTrack(trackId, peerId);
        });
        break;

      case "sdpAnswer":
        this.midToTrackId = new Map(Object.entries(deserializedMediaEvent.data.midToTrackId));
        this.onAnswer(deserializedMediaEvent.data);
        break;

      case "candidate":
        this.onRemoteCandidate(deserializedMediaEvent.data);
        break;

      case "peerJoined":
        peer = deserializedMediaEvent.data.peer;
        if (peer.id === this.getPeerId()) return;
        this.addPeer(peer);
        this.callbacks.onPeerJoined?.(peer);
        break;

      case "peerLeft":
        peer = this.idToPeer.get(deserializedMediaEvent.data.peerId)!;
        if (peer.id === this.getPeerId()) return;
        Array.from(peer.trackIdToMetadata.keys()).forEach((trackId) =>
          this.callbacks.onTrackRemoved?.(this.trackIdToTrack.get(trackId)!)
        );
        this.erasePeer(peer);
        this.callbacks.onPeerLeft?.(peer);
        break;
      case "peerUpdated":
        if (this.getPeerId() === deserializedMediaEvent.data.peerId) return;
        peer = this.idToPeer.get(deserializedMediaEvent.data.peerId)!;
        peer.metadata = deserializedMediaEvent.data.metadata;
        this.addPeer(peer);
        this.callbacks.onPeerUpdated?.(peer);
        break;
      case "trackUpdated":
        if (this.getPeerId() === deserializedMediaEvent.data.peerId) return;
        peer = this.idToPeer.get(deserializedMediaEvent.data.peerId)!;
        if (peer == null) throw `Peer with id: ${deserializedMediaEvent.data.peerId} doesn't exist`;
        const trackId = deserializedMediaEvent.data.trackId;
        const trackMetadata = deserializedMediaEvent.data.metadata;
        peer.trackIdToMetadata.set(trackId, trackMetadata);
        const trackContext = this.trackIdToTrack.get(trackId)!;
        trackContext.metadata = trackMetadata;
        this.callbacks.onTrackUpdated?.(trackContext);
        break;

      case "custom":
        this.handleMediaEvent(deserializedMediaEvent.data as MediaEvent);
        break;

      case "error":
        this.callbacks.onConnectionError?.(deserializedMediaEvent.data.message);
        this.leave();
        break;
    }
  };

  /**
   * Adds track that will be sent to the SFU server.
   * @param track - Audio or video track e.g. from your microphone or camera.
   * @param stream  - Stream that this track belongs to.
   * @param trackMetadata - Any information about this track that other peers will
   * receive in {@link onPeerJoined}. E.g. this can source of the track - wheather it's
   * screensharing, webcam or some other media device.
   * @returns {string} Returns id of added track
   * @example
   * ```ts
   * let localStream: MediaStream = new MediaStream();
   * try {
   *   localAudioStream = await navigator.mediaDevices.getUserMedia(
   *     AUDIO_CONSTRAINTS
   *   );
   *   localAudioStream
   *     .getTracks()
   *     .forEach((track) => localStream.addTrack(track));
   * } catch (error) {
   *   console.error("Couldn't get microphone permission:", error);
   * }
   *
   * try {
   *   localVideoStream = await navigator.mediaDevices.getUserMedia(
   *     VIDEO_CONSTRAINTS
   *   );
   *   localVideoStream
   *     .getTracks()
   *     .forEach((track) => localStream.addTrack(track));
   * } catch (error) {
   *  console.error("Couldn't get camera permission:", error);
   * }
   *
   * localStream
   *  .getTracks()
   *  .forEach((track) => webrtc.addTrack(track, localStream));
   * ```
   */
  public addTrack(
    track: MediaStreamTrack,
    stream: MediaStream,
    trackMetadata: any = new Map()
  ): string {
    if (this.getPeerId() === "") throw "Cannot add tracks before being accepted by the server";
    const trackId = this.getTrackId(uuidv4());
    this.localTracksWithStreams.push({ track, stream });

    this.localPeer.trackIdToMetadata.set(trackId, trackMetadata);
    this.localTrackIdToTrack.set(trackId, {
      track,
      stream,
      trackId,
      peer: this.localPeer,
      metadata: trackMetadata,
    });

    if (this.connection) {
      this.connection.addTrack(track, stream);

      this.connection
        .getTransceivers()
        .forEach(
          (trans) =>
            (trans.direction = trans.direction === "sendrecv" ? "sendonly" : trans.direction)
        );
    }

    let mediaEvent = generateCustomEvent({ type: "renegotiateTracks" });
    this.sendMediaEvent(mediaEvent);
    return trackId;
  }

  /**
   * Replaces a track that is being sent to the SFU server.
   * @param track - Audio or video track.
   * @param {string} trackId - Id of audio or video track to replace.
   * @param {MediaStreamTrack} newTrack
   * @param {any} [newMetadata] - Optional track metadata to apply to the new track. If no
   *                              track metadata is passed, the old track metadata is retained.
   * @returns {Promise<boolean>} success
   * @example
   * ```ts
   * // setup camera
   * let localStream: MediaStream = new MediaStream();
   * try {
   *   localVideoStream = await navigator.mediaDevices.getUserMedia(
   *     VIDEO_CONSTRAINTS
   *   );
   *   localVideoStream
   *     .getTracks()
   *     .forEach((track) => localStream.addTrack(track));
   * } catch (error) {
   *   console.error("Couldn't get camera permission:", error);
   * }
   * let oldTrackId;
   * localStream
   *  .getTracks()
   *  .forEach((track) => trackId = webrtc.addTrack(track, localStream));
   *
   * // change camera
   * const oldTrack = localStream.getVideoTracks()[0];
   * let videoDeviceId = "abcd-1234";
   * navigator.mediaDevices.getUserMedia({
   *      video: {
   *        ...(VIDEO_CONSTRAINTS as {}),
   *        deviceId: {
   *          exact: videoDeviceId,
   *        },
   *      }
   *   })
   *   .then((stream) => {
   *     let videoTrack = stream.getVideoTracks()[0];
   *     webrtc.replaceTrack(oldTrackId, videoTrack);
   *   })
   *   .catch((error) => {
   *     console.error('Error switching camera', error);
   *   })
   * ```
   */
  public async replaceTrack(
    trackId: string,
    newTrack: MediaStreamTrack,
    newTrackMetadata?: any
  ): Promise<boolean> {
    const trackContext = this.localTrackIdToTrack.get(trackId)!;
    const sender = this.findSender(trackContext.track!!.id);
    if (sender) {
      return sender
        .replaceTrack(newTrack)
        .then(() => {
          const trackMetadata = newTrackMetadata || this.localTrackIdToTrack.get(trackId)!.metadata;
          trackContext.track = newTrack;
          this.updateTrackMetadata(trackId, trackMetadata);
          return true;
        })
        .catch(() => false);
    }

    return false;
  }

  /**
   * Remove a track from connection that was being sent to the SFU server.
   * @param {string} trackId - Id of audio or video track to remove.
   * @example
   * ```ts
   * // setup camera
   * let localStream: MediaStream = new MediaStream();
   * try {
   *   localVideoStream = await navigator.mediaDevices.getUserMedia(
   *     VIDEO_CONSTRAINTS
   *   );
   *   localVideoStream
   *     .getTracks()
   *     .forEach((track) => localStream.addTrack(track));
   * } catch (error) {
   *   console.error("Couldn't get camera permission:", error);
   * }
   *
   * let trackId
   * localStream
   *  .getTracks()
   *  .forEach((track) => trackId = webrtc.addTrack(track, localStream));
   *
   * // remove track
   * webrtc.removeTrack(trackId)
   * ```
   */
  public removeTrack(trackId: string) {
    const trackContext = this.localTrackIdToTrack.get(trackId)!;
    const sender = this.findSender(trackContext.track!!.id);
    this.connection!.removeTrack(sender);
    let mediaEvent = generateMediaEvent("renegotiateTracks", {});
    this.sendMediaEvent(mediaEvent);
  }

  private findSender(trackId: string): RTCRtpSender {
    return this.connection!.getSenders().find(
      (sender) => sender.track && sender!.track!.id === trackId
    )!;
  }

  /**
   * Updates the metadata for the current peer.
   * @param peerMetadata - Data about this peer that other peers will receive upon joining.
   *
   * If the metadata is different from what is already tracked in the room, the optional
   * callback `onPeerUpdated` will be triggered for other peers in the room.
   */
  public updatePeerMetadata = (peerMetadata: any): void => {
    let mediaEvent = generateMediaEvent("updatePeerMetadata", {
      metadata: peerMetadata,
    });
    this.sendMediaEvent(mediaEvent);
  };

  /**
   * Updates the metadata for a specific track.
   * @param trackId - trackId (generated in addTrack) of audio or video track.
   * @param trackMetadata - Data about this track that other peers will receive upon joining.
   *
   * If the metadata is different from what is already tracked in the room, the optional
   * callback `onTrackUpdated` will be triggered for other peers in the room.
   */
  public updateTrackMetadata = (trackId: string, trackMetadata: any): void => {
    const trackContext = this.localTrackIdToTrack.get(trackId)!;
    trackContext.metadata = trackMetadata;
    this.localTrackIdToTrack.set(trackId, trackContext);

    this.localPeer.trackIdToMetadata.set(trackId, trackMetadata);
    let mediaEvent = generateMediaEvent("updateTrackMetadata", {
      trackId,
      trackMetadata,
    });
    this.sendMediaEvent(mediaEvent);
  };

  private getMidToTrackId = () => {
    const localTrackMidToTrackId = {} as any;

    if (!this.connection) return null;
    this.connection.getTransceivers().forEach((transceiver) => {
      const localTrackId = transceiver.sender.track?.id;
      const mid = transceiver.mid;
      const trackIds = this.localPeer.trackIdToMetadata.keys();
      const tracks = Array.from(trackIds).map((track) => this.localTrackIdToTrack.get(track));

      if (localTrackId && mid) {
        const trackContext = tracks.find(
          (trackContext) => trackContext!.track!!.id === localTrackId
        )!;
        localTrackMidToTrackId[mid] = trackContext.trackId;
      }
    });
    return localTrackMidToTrackId;
  };

  /**
   * Leaves the room. This function should be called when user leaves the room
   * in a clean way e.g. by clicking a dedicated, custom button `disconnect`.
   * As a result there will be generated one more media event that should be
   * sent to the SFU server. Thanks to it each other peer will be notified
   * that peer left in {@link onPeerLeft},
   */
  public leave = () => {
    let mediaEvent = generateMediaEvent("leave");
    this.sendMediaEvent(mediaEvent);
    this.cleanUp();
  };

  /**
   * Cleans up {@link MembraneWebRTC} instance.
   */
  public cleanUp = () => {
    if (this.connection) {
      this.connection.onicecandidate = null;
      this.connection.ontrack = null;
    }

    this.localTracksWithStreams.forEach(({ track }) => track.stop());
    this.localTracksWithStreams = [];
    this.connection = undefined;
  };

  private getTrackId(uuid: string): string {
    return `${this.getPeerId()}:${uuid}`;
  }

  private sendMediaEvent = (mediaEvent: MediaEvent) => {
    this.callbacks.onSendMediaEvent(serializeMediaEvent(mediaEvent));
  };

  private onAnswer = async (answer: RTCSessionDescriptionInit) => {
    this.connection!.ontrack = this.onTrack();
    try {
      await this.connection!.setRemoteDescription(answer);
    } catch (err) {
      console.log(err);
    }
  };

  private addTransceiversIfNeeded = (serverTracks: Map<string, number>) => {
    const recvTransceivers = this.connection!.getTransceivers().filter(
      (elem) => elem.direction === "recvonly"
    );
    let toAdd: string[] = [];

    const getNeededTransceiversTypes = (type: string): string[] => {
      let typeNumber = serverTracks.get(type);
      typeNumber = typeNumber !== undefined ? typeNumber : 0;
      const typeTransceiversNumber = recvTransceivers.filter(
        (elem) => elem.receiver.track.kind === type
      ).length;
      return Array(typeNumber - typeTransceiversNumber).fill(type);
    };

    const audio = getNeededTransceiversTypes("audio");
    const video = getNeededTransceiversTypes("video");
    toAdd = toAdd.concat(audio);
    toAdd = toAdd.concat(video);

    for (let kind of toAdd) this.connection?.addTransceiver(kind, { direction: "recvonly" });
  };

  private async createAndSendOffer() {
    if (!this.connection) return;
    try {
      const offer = await this.connection.createOffer();
      await this.connection.setLocalDescription(offer);

      let mediaEvent = generateCustomEvent({
        type: "sdpOffer",
        data: {
          sdpOffer: offer,
          trackIdToTrackMetadata: this.getTrackIdToMetadata(),
          midToTrackId: this.getMidToTrackId(),
        },
      });
      this.sendMediaEvent(mediaEvent);
    } catch (error) {
      console.error(error);
    }
  }

  private getTrackIdToMetadata = () => {
    const trackIdToMetadata = {} as any;
    Array.from(this.localPeer.trackIdToMetadata.entries()).forEach(([trackId, metadata]) => {
      trackIdToMetadata[trackId] = metadata;
    });
    return trackIdToMetadata;
  };

  private onOfferData = async (offerData: Map<string, number>) => {
    if (!this.connection) {
      this.connection = new RTCPeerConnection(this.rtcConfig);
      this.connection.onicecandidate = this.onLocalCandidate();

      this.localTracksWithStreams.forEach(({ track, stream }) => {
        this.connection!.addTrack(track, stream);
      });

      this.connection.getTransceivers().forEach((trans) => (trans.direction = "sendonly"));
    } else {
      await this.connection.restartIce();
    }

    this.addTransceiversIfNeeded(offerData);

    await this.createAndSendOffer();
  };

  private onRemoteCandidate = (candidate: RTCIceCandidate) => {
    try {
      const iceCandidate = new RTCIceCandidate(candidate);
      if (!this.connection) {
        throw new Error("Received new remote candidate but RTCConnection is undefined");
      }
      this.connection.addIceCandidate(iceCandidate);
    } catch (error) {
      console.error(error);
    }
  };

  private onLocalCandidate = () => {
    return (event: RTCPeerConnectionIceEvent) => {
      if (event.candidate) {
        let mediaEvent = generateCustomEvent({
          type: "candidate",
          data: {
            candidate: event.candidate.candidate,
            sdpMLineIndex: event.candidate.sdpMLineIndex,
          },
        });
        this.sendMediaEvent(mediaEvent);
      }
    };
  };

  private onTrack = () => {
    return (event: RTCTrackEvent) => {
      const [stream] = event.streams;
      const mid = event.transceiver.mid!;

      const trackId = this.midToTrackId.get(mid)!;

      const peer = Array.from(this.idToPeer.values()).filter((peer) =>
        Array.from(peer.trackIdToMetadata.keys()).includes(trackId)
      )[0];

      const metadata = peer.trackIdToMetadata.get(trackId);
      const trackContext = {
        stream,
        track: event.track,
        peer: peer,
        trackId,
        metadata,
      };

      this.trackIdToTrack.set(trackId, trackContext);

      this.callbacks.onTrackReady?.(trackContext);
    };
  };

  private setTurns = (turnServers: any[], iceTransportPolicy: "relay" | "all"): void => {
    if (!this.rtcConfig.iceServers) {
      this.rtcConfig.iceServers = [];
    }

    if (iceTransportPolicy === "relay") {
      this.rtcConfig.iceTransportPolicy = "relay";

      turnServers.forEach((turnServer: any) => {
        const rtcIceServer: RTCIceServer = {
          credential: turnServer.password,
          credentialType: "password",
          urls: "turn".concat(
            ":",
            turnServer.serverAddr,
            ":",
            turnServer.serverPort,
            "?transport=",
            turnServer.transport
          ),
          username: turnServer.username,
        };

        this.rtcConfig.iceServers!.push(rtcIceServer);
      });
    }
  };

  private addPeer = (peer: Peer): void => {
    // #TODO remove this line after fixing deserialization
    peer.trackIdToMetadata = new Map(Object.entries(peer.trackIdToMetadata));
    this.idToPeer.set(peer.id, peer);
  };

  private erasePeer = (peer: Peer): void => {
    const tracksId = Array.from(peer.trackIdToMetadata.keys());
    tracksId.forEach((trackId) => this.trackIdToTrack.delete(trackId));
    Array.from(this.midToTrackId.entries()).forEach(([mid, trackId]) => {
      if (tracksId.includes(trackId)) this.midToTrackId.delete(mid);
    });
    this.idToPeer.delete(peer.id);
  };

  private eraseTrack = (trackId: string, peerId: string) => {
    this.trackIdToTrack.delete(trackId);
    const midToTrackId = Array.from(this.midToTrackId.entries());
    const [mid, _trackId] = midToTrackId.find(([mid, mapTrackId]) => mapTrackId === trackId)!;
    this.midToTrackId.delete(mid);
    this.idToPeer.get(peerId)!.trackIdToMetadata.delete(trackId);
  };

  private getPeerId = () => this.localPeer.id;
}
