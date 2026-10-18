defmodule RintoError.Message do
  @moduledoc false

  @inspect_opts [pretty: true, width: 80, limit: :infinity, printable_limit: :infinity]
  @fields [:kind, :message, :data, :errors, :metadata]

  @doc false
  @spec format(struct(), keyword()) :: String.t()
  def format(%{__struct__: module} = error, inspect_opts \\ []) do
    opts =
      @inspect_opts
      |> Keyword.merge(Application.get_env(:rinto_error, :inspect_opts, []))
      |> Keyword.merge(inspect_opts)

    fields =
      Enum.map_join(@fields, "\n", fn field ->
        value =
          error
          |> Map.fetch!(field)
          |> inspect(opts)
          |> String.replace("\n", "\n  ")

        "  #{field}: #{value}"
      end)

    "#{inspect(module)}\n#{fields}"
  end
end
