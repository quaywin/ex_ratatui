defmodule ExRatatui.Property.NormalizePropertyTest do
  @moduledoc """
  Property-based invariants for `ExRatatui.Subscription.normalize/1` and
  `ExRatatui.Command.normalize/1`.

  Both helpers flatten a user-shaped argument (`nil`, a single struct, a
  list of structs, or a nested mix) into a flat list of leaf structs. The
  same handful of invariants applies to both — idempotence, order
  preservation, length preservation, and refusal of garbage shapes — so
  they share a generator surface and live in one file.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Command
  alias ExRatatui.Subscription

  # Generators -------------------------------------------------------------

  defp subscription_leaf_gen do
    gen all(
          kind <- member_of([:interval, :once]),
          id <- one_of([atom(:alphanumeric), integer()]),
          interval_ms <- positive_integer(),
          message <- term()
        ) do
      %Subscription{id: id, kind: kind, interval_ms: interval_ms, message: message}
    end
  end

  defp subscription_input_gen do
    one_of([
      constant(nil),
      constant([]),
      subscription_leaf_gen(),
      list_of(subscription_leaf_gen(), max_length: 6),
      # nested lists — Subscription.normalize handles a flat list of structs
      # (no nested batch struct exists), so we exercise list-of-leaves here.
      list_of(one_of([constant(nil), subscription_leaf_gen()]), max_length: 6)
    ])
  end

  defp command_leaf_gen do
    one_of([
      gen all(message <- term()) do
        %Command{kind: :message, message: message}
      end,
      gen all(delay <- integer(0..10_000), message <- term()) do
        %Command{kind: :after, delay_ms: delay, message: message}
      end
    ])
  end

  # A non-batch leaf or a batch wrapping arbitrary leaves — bounded depth
  # so we don't spend the property budget generating deeply pathological
  # trees. The recursive `tree/2` constructor makes nesting depth explicit.
  defp command_input_gen do
    one_of([
      constant(nil),
      constant([]),
      command_leaf_gen(),
      tree(command_leaf_gen(), fn child ->
        one_of([
          gen all(commands <- list_of(child, max_length: 4)) do
            %Command{kind: :batch, commands: commands}
          end,
          list_of(child, max_length: 4)
        ])
      end)
    ])
  end

  # Helpers ----------------------------------------------------------------

  # Counts the leaf (non-batch) Command structs reachable from `term`,
  # treating nil and [] as zero leaves and recursing through lists +
  # %Command{kind: :batch}.
  defp count_command_leaves(nil), do: 0
  defp count_command_leaves([]), do: 0
  defp count_command_leaves(%Command{kind: :batch, commands: cs}), do: count_command_leaves(cs)
  defp count_command_leaves(%Command{}), do: 1

  defp count_command_leaves(list) when is_list(list),
    do: Enum.sum(Enum.map(list, &count_command_leaves/1))

  # Properties: Subscription.normalize -------------------------------------

  describe "Subscription.normalize/1" do
    property "always returns a flat list of %Subscription{}" do
      check all(input <- subscription_input_gen()) do
        result = Subscription.normalize(input)
        assert is_list(result)
        assert Enum.all?(result, &match?(%Subscription{}, &1))
      end
    end

    property "is idempotent" do
      check all(input <- subscription_input_gen()) do
        once = Subscription.normalize(input)
        twice = Subscription.normalize(once)
        assert once == twice
      end
    end

    property "length matches the number of struct leaves in the input" do
      check all(leaves <- list_of(subscription_leaf_gen(), max_length: 6)) do
        assert length(Subscription.normalize(leaves)) == length(leaves)
      end
    end

    property "preserves order across a flat list" do
      check all(leaves <- list_of(subscription_leaf_gen(), max_length: 6)) do
        assert Subscription.normalize(leaves) == leaves
      end
    end

    property "raises ArgumentError on unsupported shapes" do
      garbage_gen =
        one_of([
          atom(:alphanumeric),
          string(:printable),
          integer(),
          float(),
          map_of(string(:printable), integer(), max_length: 3)
        ])

      check all(garbage <- garbage_gen) do
        assert_raise ArgumentError, fn -> Subscription.normalize(garbage) end
      end
    end
  end

  # Properties: Command.normalize ------------------------------------------

  describe "Command.normalize/1" do
    property "always returns a flat list of non-batch %Command{}" do
      check all(input <- command_input_gen()) do
        result = Command.normalize(input)
        assert is_list(result)

        assert Enum.all?(result, fn
                 %Command{kind: :batch} -> false
                 %Command{} -> true
                 _ -> false
               end)
      end
    end

    property "is idempotent" do
      check all(input <- command_input_gen()) do
        once = Command.normalize(input)
        twice = Command.normalize(once)
        assert once == twice
      end
    end

    property "flattens nested batches preserving leaf count" do
      check all(input <- command_input_gen()) do
        assert length(Command.normalize(input)) == count_command_leaves(input)
      end
    end

    property "preserves leaf order under flattening" do
      # Build inputs whose leaf order is statically known (a flat list of
      # leaves), so the property has a definite expected shape regardless
      # of how nested batches reshuffle internal layout. Nested batches are
      # exercised by the previous "leaf count" property.
      check all(leaves <- list_of(command_leaf_gen(), max_length: 6)) do
        assert Command.normalize(leaves) == leaves
      end
    end

    property "raises ArgumentError on unsupported shapes" do
      garbage_gen =
        one_of([
          atom(:alphanumeric),
          string(:printable),
          integer(),
          float(),
          map_of(string(:printable), integer(), max_length: 3)
        ])

      check all(garbage <- garbage_gen) do
        assert_raise ArgumentError, fn -> Command.normalize(garbage) end
      end
    end
  end
end
