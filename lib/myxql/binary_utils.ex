defmodule MyXQL.BinaryUtils do
  @moduledoc false

  defmacro int(size) do
    quote do
      little-integer-size(unquote(size))-unit(8)
    end
  end
end
