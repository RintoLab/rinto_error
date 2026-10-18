defmodule RintoError.ChangesetNumberTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.Error

  test "encodes Decimal bounds exactly for every numeric comparison" do
    bound = Decimal.new("9007199254740993.1234567890")

    for {comparison, value} <- [
          {:greater_than, bound},
          {:greater_than_or_equal_to, Decimal.sub(bound, 1)},
          {:less_than, bound},
          {:less_than_or_equal_to, Decimal.add(bound, 1)},
          {:equal_to, Decimal.add(bound, 1)},
          {:not_equal_to, bound}
        ] do
      changeset =
        Changeset.cast({%{}, %{value: :decimal}}, %{value: value}, [:value])
        |> Changeset.validate_number(:value, [{comparison, bound}])

      assert_number_payload(changeset, comparison, "9007199254740993.1234567890")
    end
  end

  test "retains integer and float bound values" do
    for {type, bound} <- [{:integer, 3}, {:float, 3.5}] do
      changeset =
        Changeset.cast({%{}, %{value: type}}, %{value: 1}, [:value])
        |> Changeset.validate_number(:value, greater_than: bound)

      assert_number_payload(changeset, :greater_than, bound)
    end
  end

  test "preserves Decimal values in caller data and unrelated metadata" do
    bound = Decimal.new("1.00")

    changeset =
      Changeset.change({%{}, %{value: :decimal}})
      |> Changeset.add_error(:value, "custom", number: bound, validation: :custom)

    error = %{Error.exception(changeset) | data: %{number: bound}}
    payload = Error.to_payload(error)

    assert payload.data == %{number: bound}
    assert [%{data: %{number: ^bound}}] = payload.errors
    assert error.raw == changeset
  end

  defp assert_number_payload(changeset, comparison, bound) do
    refute changeset.valid?
    original_error = Keyword.fetch!(changeset.errors, :value)
    error = Error.exception(changeset)
    payload = Error.to_payload(error)

    assert payload.errors == [
             %{
               kind: :number,
               data: %{path: ["value"], kind: comparison, number: bound},
               errors: []
             }
           ]

    assert error.raw == changeset
    assert RintoError.Changeset.to_errors(changeset) == payload.errors
    assert Keyword.fetch!(error.raw.errors, :value) == original_error
    assert Jason.encode!(error) == Jason.encode!(payload)

    if Code.ensure_loaded?(JSON) do
      assert apply(JSON, :encode!, [error]) == apply(JSON, :encode!, [payload])
    end
  end
end
