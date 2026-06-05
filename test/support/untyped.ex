defmodule ExRatatui.Test.Untyped do
  @moduledoc false

  @doc """
  Returns `value` unchanged, but typed as `term()` so Elixir's compile-time
  type checker can't see its concrete type.

  Negative tests deliberately pass invalid arguments — wrong type, empty
  list, unknown atom — to assert a guard or `FunctionClauseError` fires. As
  of Elixir 1.20 the type checker flags those literals as "incompatible
  types" before the test ever runs. Routing the value through this
  `term()`-spec'd identity defeats that inference while preserving the exact
  runtime term (safe for NIF resource references, which a serialization
  round-trip would invalidate).
  """
  @spec untyped(term()) :: term()
  def untyped(value), do: value
end
