defmodule Membrane.RTC.Engine.Endpoint.WebRTC.ConnectionAllocator do
  @moduledoc """
  Behavior defining a set of functions for managing connection allocations for TrackReceivers.

  It is responsible for allocating connection bandwidth for track receivers and probing the connection.
  """

  alias Membrane.Buffer
  alias Membrane.RTC.Engine.Track

  @doc """
  Function invoked by the TrackReceiver whenever a buffer is sent
  """
  @callback buffer_sent(pid(), Buffer.t()) :: :ok

  @doc """
  Function invoked by the TrackReceiver whenever a padding packet is sent
  """
  @callback probe_sent(pid()) :: :ok

  @doc """
  Function called by the TrackReceiver to register itself in the allocator
  """
  @callback say_hello(pid(), number(), Track.t()) :: :ok

  @doc """
  A function called by the endpoint, to update the bandwidth estimation in the allocator
  """
  @callback update_bandwidth_estimation(pid(), number()) :: :ok

  @callback request_allocation(pid(), number()) :: :ok
end
