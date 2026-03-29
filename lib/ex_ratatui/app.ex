defmodule ExRatatui.App do
  @moduledoc """
  A behaviour for building supervised TUI applications.

  Provides a LiveView-inspired callback interface for terminal apps
  that can be placed in OTP supervision trees.

  ## Usage

      defmodule MyTUI do
        use ExRatatui.App

        @impl true
        def mount(_opts) do
          {:ok, %{count: 0}}
        end

        @impl true
        def render(state, frame) do
          alias ExRatatui.Widgets.Paragraph
          alias ExRatatui.Layout.Rect

          widget = %Paragraph{text: "Count: \#{state.count}"}
          rect = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
          [{widget, rect}]
        end

        @impl true
        def handle_event(%ExRatatui.Event.Key{code: "q"}, state) do
          {:stop, state}
        end

        def handle_event(_event, state) do
          {:noreply, state}
        end
      end

  Then add to your supervision tree:

      children = [{MyTUI, []}]
      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

  Options are passed through `start_link/1` and forwarded to `mount/1`:

    * `:name` - process registration name (defaults to the module name,
      pass `nil` to skip registration)
    * `:poll_interval` - event polling interval in milliseconds (default: `16`,
      which gives ~60fps). The poll runs on the BEAM's DirtyIo scheduler so it
      never blocks normal processes. Lower values increase responsiveness but
      use more CPU; higher values reduce CPU but add input latency.
    * `:test_mode` - `{width, height}` tuple to use a headless test terminal
      instead of the real terminal. Enables `async: true` tests without a TTY.

  ## Callbacks

    * `mount/1` — Called once on startup with options. Return `{:ok, initial_state}`
      or `{:error, reason}` to abort startup.
    * `render/2` — Called after every state change. Receives state and a
      `%ExRatatui.Frame{}` with terminal dimensions. Return a list of
      `{widget, rect}` tuples.
    * `handle_event/2` — Called when a terminal event arrives. Return
      `{:noreply, new_state}` or `{:stop, state}`.
    * `handle_info/2` — Called for non-terminal messages (e.g., PubSub).
      Optional; default implementation returns `{:noreply, state}`.
    * `terminate/2` — Called when the TUI is shutting down. Receives the
      exit reason and final state. Optional; default is a no-op.
      Use this to stop the VM with `System.stop(0)` in standalone apps.
  """

  @type state :: term()

  @doc """
  Called once on startup with the options passed to `start_link/1`.

  Return `{:ok, initial_state}` to proceed or `{:error, reason}` to abort.
  """
  @callback mount(opts :: keyword()) :: {:ok, state()} | {:error, reason :: term()}

  @doc """
  Called after every state change to produce the UI.

  Receives the current state and a `%ExRatatui.Frame{}` with the terminal
  dimensions. Return a list of `{widget, rect}` tuples to render.
  """
  @callback render(state(), ExRatatui.Frame.t()) :: [
              {ExRatatui.widget(), ExRatatui.Layout.Rect.t()}
            ]

  @doc """
  Called when a terminal event (key, mouse, or resize) arrives.

  Return `{:noreply, new_state}` to continue or `{:stop, state}` to
  shut down the application.
  """
  @callback handle_event(
              ExRatatui.Event.Key.t() | ExRatatui.Event.Mouse.t() | ExRatatui.Event.Resize.t(),
              state()
            ) ::
              {:noreply, state()} | {:stop, state()}

  @doc """
  Called for non-terminal messages (e.g. PubSub broadcasts, `send/2`).

  Optional — the default implementation returns `{:noreply, state}`.
  """
  @callback handle_info(msg :: term(), state()) :: {:noreply, state()} | {:stop, state()}

  @doc """
  Called when the TUI is shutting down.

  Receives the exit reason and the final state. Optional — the default
  is a no-op. Use this to call `System.stop(0)` in standalone apps.
  """
  @callback terminate(reason :: term(), state()) :: term()

  @optional_callbacks [handle_info: 2, terminate: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour ExRatatui.App

      @doc false
      def handle_info(_msg, state), do: {:noreply, state}

      @doc false
      def terminate(_reason, _state), do: :ok

      defoverridable handle_info: 2, terminate: 2

      @doc false
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :transient
        }
      end

      @doc false
      def start_link(opts \\ []) when is_list(opts) do
        ExRatatui.Server.start_link(Keyword.put(opts, :mod, __MODULE__))
      end
    end
  end
end
