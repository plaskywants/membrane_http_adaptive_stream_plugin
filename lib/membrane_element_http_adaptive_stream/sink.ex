defmodule Membrane.Element.HTTPAdaptiveStream.Sink do
  use Bunch
  use Membrane.Sink
  alias Membrane.Element.HTTPAdaptiveStream.{Playlist, Storage}

  def_input_pad :input,
    availability: :on_request,
    demand_unit: :buffers,
    caps: Membrane.Caps.HTTPAdaptiveStream.Track

  def_options playlist_name: [
                type: :string,
                spec: String.t(),
                default: "index"
              ],
              playlist_module: [
                type: :atom,
                spec: module
              ],
              storage: [
                type: :struct,
                spec: Storage.config_t()
              ],
              windowed?: [
                type: :bool,
                default: true
              ],
              target_window_duration: [
                spec: pos_integer | :infinity | nil,
                default: nil
              ],
              target_fragment_duration: [
                type: :time,
                default: 0
              ]

  @impl true
  def handle_init(options) do
    options
    |> Map.take([:playlist_module, :max_fragments, :target_duration])
    |> Map.merge(%{
      storage: Storage.new(options.storage),
      playlist: %Playlist{name: options.playlist_name},
      to_notify: MapSet.new()
    })
    ~> {:ok, &1}
  end

  @impl true
  def handle_caps(Pad.ref(:input, id), caps, _ctx, state) do
    {init_name, playlist} =
      Playlist.add_track(
        state.playlist,
        %Playlist.Track.Config{
          id: id,
          content_type: caps.content_type,
          init_extension: caps.init_extension,
          fragment_extension: caps.fragment_extension,
          target_window_duration: state.target_fragment_duration,
          target_fragment_duration: state.target_fragment_duration
        }
      )

    state = %{state | playlist: playlist}
    {result, storage} = Storage.store_init(state.storage, init_name, caps.init)
    {result, %{state | storage: storage}}
  end

  @impl true
  def handle_start_of_stream(Pad.ref(:input, id) = pad, _ctx, state) do
    to_notify = MapSet.put(state.to_notify, id)
    {{:ok, demand: pad}, %{state | to_notify: to_notify}}
  end

  @impl true
  def handle_write(Pad.ref(:input, id) = pad, buffer, _ctx, state) do
    duration = buffer.metadata.duration
    {changeset, playlist} = Playlist.add_fragment(state.playlist, id, duration)
    state = %{state | playlist: playlist}

    %{
      storage: storage,
      playlist_module: playlist_module,
      windowed?: windowed?,
      to_notify: to_notify
    } = state

    with {:ok, storage} <- Storage.apply_chunk_changeset(storage, changeset, buffer.payload),
         {:ok, storage} <-
           maybe_store_playlists(storage, playlist_module.serialize(playlist), windowed?) do
      {notify, state} =
        if MapSet.member?(to_notify, id) do
          {[notify: {:stream_playable, id}], %{state | to_notify: MapSet.delete(to_notify, id)}}
        else
          {[], state}
        end

      {{:ok, notify ++ [demand: pad]}, %{state | storage: storage}}
    else
      {error, storage} -> {error, %{state | storage: storage}}
    end
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, id), _ctx, state) do
    {playlist, state} = Bunch.Map.get_updated!(state, :playlist, &Playlist.finish(&1, id))

    {result, storage} =
      maybe_store_playlists(
        state.storage,
        state.playlist_module.serialize(playlist),
        state.windowed?
      )

    {result, %{state | storage: storage}}
  end

  defp maybe_store_playlists(storage, playlists, true) do
    Storage.store_playlists(storage, playlists)
  end

  defp maybe_store_playlists(storage, _playlists, false) do
    {:ok, storage}
  end
end
