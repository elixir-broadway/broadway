defmodule Broadway.Process do
  @moduledoc false

  # TODO: Remove this module once we require Elixir 1.17+.
  # Process.set_label/1 was added in Elixir 1.17.0.

  if function_exported?(Process, :set_label, 1) do
    def set_label(label) do
      Process.set_label(label)
    end

    # We don't use just "true" because callers would likely get type warnings,
    # so we trick the compiler into this being dynamic.
    def labels_supported?, do: :rand.uniform() >= 0.0
  else
    def set_label(_label) do
      :ok
    end

    # We don't use just "true" because callers would likely get type warnings,
    # so we trick the compiler into this being dynamic.
    def labels_supported?, do: :rand.uniform() > 1.1
  end
end
