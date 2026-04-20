defmodule ExRatatui.Test.PeerWidgetsApp do
  @moduledoc false
  # Distributed-integration fixture that renders a frame containing recently
  # added widgets (Chart, BarChart with groups, Canvas with a Map shape) so the
  # test can assert they survive the node boundary as plain BEAM terms. If
  # any of these ever grows a NIF-backed field, this test will fail loudly.

  use ExRatatui.App

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Bar, BarChart, BarGroup, Canvas, Chart}
  alias ExRatatui.Widgets.Canvas.Map, as: CanvasMap
  alias ExRatatui.Widgets.Chart.{Axis, Dataset}

  @impl true
  def mount(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:mounted, self(), opts})
    {:ok, %{test_pid: test_pid}}
  end

  @impl true
  def render(_state, frame) do
    chart = %Chart{
      datasets: [
        %Dataset{
          name: "series",
          data: [{0.0, 1.0}, {1.0, 2.0}, {2.0, 1.5}],
          marker: :braille,
          graph_type: :line,
          style: %Style{fg: :cyan}
        }
      ],
      x_axis: %Axis{bounds: {0.0, 2.0}, labels: ["0", "2"]},
      y_axis: %Axis{bounds: {0.0, 3.0}, labels: ["0", "3"]}
    }

    bar_chart = %BarChart{
      groups: [
        %BarGroup{
          label: "Q1",
          bars: [
            %Bar{label: "Elixir", value: 80},
            %Bar{label: "Rust", value: 95}
          ]
        }
      ],
      group_gap: 2
    }

    canvas = %Canvas{
      x_bounds: {-180.0, 180.0},
      y_bounds: {-90.0, 90.0},
      marker: :braille,
      shapes: [%CanvasMap{resolution: :low, color: :green}]
    }

    w = frame.width
    h = frame.height
    third = div(h, 3)

    [
      {chart, %Rect{x: 0, y: 0, width: w, height: third}},
      {bar_chart, %Rect{x: 0, y: third, width: w, height: third}},
      {canvas, %Rect{x: 0, y: 2 * third, width: w, height: h - 2 * third}}
    ]
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "q"}, state) do
    {:stop, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    send(state.test_pid, {:terminated, reason})
    :ok
  end
end
