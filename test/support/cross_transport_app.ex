defmodule ExRatatui.Test.CrossTransportApp do
  @moduledoc false
  # Shared test App used by cross-transport integration tests to verify
  # that the same module produces the same widget tree regardless of
  # whether it's mounted locally, over SSH, or over Erlang distribution.
  #
  # Sends `{:rendered, self(), widgets}` to the configured `:test_pid`
  # from every render, so the harness can compare trees across
  # transports.

  use ExRatatui.App

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph}

  @impl true
  def mount(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:mounted, self()})
    {:ok, %{test_pid: test_pid, count: 0}}
  end

  @impl true
  def render(%{test_pid: test_pid, count: count}, frame) do
    widgets = [
      {%Block{title: "cross-transport", borders: [:all]},
       %Rect{x: 0, y: 0, width: frame.width, height: frame.height}},
      {%Paragraph{text: "count: #{count}"}, %Rect{x: 2, y: 2, width: frame.width - 4, height: 1}}
    ]

    send(test_pid, {:rendered, self(), widgets})
    widgets
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "q"}, state) do
    {:stop, state}
  end

  def handle_event(_event, state) do
    {:noreply, %{state | count: state.count + 1}}
  end

  @impl true
  def terminate(reason, state) do
    send(state.test_pid, {:terminated, self(), reason})
    :ok
  end
end
