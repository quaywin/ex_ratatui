defmodule ExRatatui.LayoutTest do
  use ExUnit.Case, async: true

  doctest ExRatatui.Layout
  doctest ExRatatui.Layout.Rect

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect

  describe "split/3" do
    test "vertical split with percentages" do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}
      [top, bottom] = Layout.split(area, :vertical, [{:percentage, 50}, {:percentage, 50}])

      assert %Rect{x: 0, y: 0, width: 80, height: 12} = top
      assert %Rect{x: 0, y: 12, width: 80, height: 12} = bottom
    end

    test "horizontal split with percentages" do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}
      [left, right] = Layout.split(area, :horizontal, [{:percentage, 50}, {:percentage, 50}])

      assert %Rect{x: 0, y: 0, width: 40, height: 24} = left
      assert %Rect{x: 40, y: 0, width: 40, height: 24} = right
    end

    test "vertical split with length and min" do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}
      [header, body] = Layout.split(area, :vertical, [{:length, 3}, {:min, 0}])

      assert header.height == 3
      assert body.y == 3
      assert body.height == 21
    end

    test "three-way vertical split" do
      area = %Rect{x: 0, y: 0, width: 60, height: 30}

      [header, body, footer] =
        Layout.split(area, :vertical, [{:length, 3}, {:min, 0}, {:length, 1}])

      assert %Rect{x: 0, y: 0, width: 60, height: 3} = header
      assert %Rect{x: 0, y: 3, width: 60, height: 26} = body
      assert %Rect{x: 0, y: 29, width: 60, height: 1} = footer
    end

    test "split with offset area" do
      area = %Rect{x: 5, y: 5, width: 40, height: 20}
      [left, right] = Layout.split(area, :horizontal, [{:percentage, 50}, {:percentage, 50}])

      assert %Rect{x: 5, y: 5, width: 20, height: 20} = left
      assert %Rect{x: 25, y: 5, width: 20, height: 20} = right
    end

    test "ratio constraint" do
      area = %Rect{x: 0, y: 0, width: 90, height: 24}
      [left, right] = Layout.split(area, :horizontal, [{:ratio, 1, 3}, {:ratio, 2, 3}])

      assert left.width == 30
      assert right.width == 60
    end

    test "max constraint" do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}
      [top, bottom] = Layout.split(area, :vertical, [{:max, 5}, {:min, 0}])

      assert top.height == 5
      assert bottom.height == 19
    end

    test "returns Rect structs" do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}
      results = Layout.split(area, :vertical, [{:percentage, 100}])

      assert [%Rect{}] = results
    end

    test "single constraint returns single rect" do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}
      [rect] = Layout.split(area, :vertical, [{:percentage, 100}])

      assert rect == area
    end

    test "returns error for invalid constraints" do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}
      assert {:error, _reason} = Layout.split(area, :vertical, [{:ratio, 1, 0}])
    end
  end
end
