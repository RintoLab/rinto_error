defmodule RintoError.ChangesetEnumTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.Error

  defmodule CustomCandidate do
    defstruct [:duration]
  end

  for {validation, type, value} <- [
        {:inclusion, :integer, 11},
        {:subset, {:array, :integer}, [11]},
        {:exclusion, :integer, 5}
      ] do
    @validation validation
    @field_type type
    @field_value value

    test "encodes Range candidates from #{@validation} validation" do
      changeset = validate(@validation, @field_type, @field_value, 1..10)

      assert_enum_payload(changeset, @validation, %{t: :range, first: 1, last: 10, step: 1})
    end

    test "encodes MapSet candidates from #{@validation} validation" do
      changeset = validate(@validation, @field_type, @field_value, MapSet.new([9, 1, 5]))

      assert_enum_payload(changeset, @validation, [1, 5, 9])
    end
  end

  for {validation, type, value} <- [
        {:inclusion, :duration, Duration.new!(day: 2)},
        {:subset, {:array, :duration}, [Duration.new!(day: 2)]},
        {:exclusion, :duration, Duration.new!(day: 1)}
      ] do
    @validation validation
    @field_type type
    @field_value value

    test "encodes Duration candidates from #{@validation} validation in lists and sets" do
      candidates = [Duration.new!(day: 1)]

      for candidates <- [candidates, MapSet.new(candidates)] do
        changeset = validate(@validation, @field_type, @field_value, candidates)
        assert_enum_payload(changeset, @validation, ["P1D"])
      end
    end
  end

  test "encodes Duration values nested inside array and map candidates" do
    one_day = Duration.new!(day: 1)
    two_days = Duration.new!(day: 2)

    for {type, value, candidates, expected} <- [
          {{:array, :duration}, [two_days], [[one_day]], [["P1D"]]},
          {{:map, :duration}, %{period: two_days}, [%{period: one_day}], [%{period: "P1D"}]},
          {:map, %{"periods" => [two_days]}, [%{"periods" => [one_day]}],
           [%{"periods" => ["P1D"]}]}
        ] do
      changeset = validate(:inclusion, type, value, candidates)
      assert_enum_payload(changeset, :inclusion, expected)
    end
  end

  test "preserves existing encoder-supported scalar candidates" do
    for {type, value, candidate} <- [
          {:string, "other", "allowed"},
          {:float, 2.0, 1.0},
          {:boolean, false, true},
          {:date, ~D[2026-10-02], ~D[2026-10-01]},
          {:time, ~T[10:00:00], ~T[09:00:00]},
          {:utc_datetime, ~U[2026-10-02 00:00:00Z], ~U[2026-10-01 00:00:00Z]},
          {:naive_datetime, ~N[2026-10-02 00:00:00], ~N[2026-10-01 00:00:00]}
        ] do
      changeset = validate(:inclusion, type, value, [candidate])
      assert_enum_payload(changeset, :inclusion, [candidate])
    end
  end

  test "encodes Decimal candidates without depending on their encoder implementation" do
    candidate = Decimal.new("9007199254740993.1234567890")

    for candidates <- [[candidate], MapSet.new([candidate])] do
      changeset = validate(:inclusion, :decimal, Decimal.new("1"), candidates)
      assert_enum_payload(changeset, :inclusion, ["9007199254740993.1234567890"])
    end

    changeset =
      validate(:inclusion, {:array, :decimal}, [Decimal.new("1")], [[candidate]])

    assert_enum_payload(changeset, :inclusion, [["9007199254740993.1234567890"]])
  end

  test "does not dismantle unknown structs or enumerate arbitrary candidate streams" do
    duration = Duration.new!(day: 1)
    custom = %CustomCandidate{duration: duration}
    stream = Stream.map([1], fn _ -> raise "must not enumerate" end)

    for candidates <- [[custom], stream] do
      changeset =
        Changeset.change({%{}, %{value: :map}})
        |> Changeset.add_error(:value, "invalid", validation: :inclusion, enum: candidates)

      payload = changeset |> Error.exception() |> Error.to_payload()
      assert [%{data: %{enum: ^candidates}}] = payload.errors
    end
  end

  for {validation, type, value} <- [
        {:inclusion, :date, ~D[2026-10-11]},
        {:subset, {:array, :date}, [~D[2026-10-11]]},
        {:exclusion, :date, ~D[2026-10-05]}
      ] do
    @validation validation
    @field_type type
    @field_value value

    test "encodes Date.Range candidates from #{@validation} validation" do
      candidates = Date.range(~D[2026-10-01], ~D[2026-10-10])
      changeset = validate(@validation, @field_type, @field_value, candidates)

      assert_enum_payload(changeset, @validation, %{
        t: :date_range,
        first: "2026-10-01",
        last: "2026-10-10",
        step: 1
      })
    end
  end

  test "preserves descending, stepped, empty, and large ranges without expansion" do
    for {range, expected} <- [
          {10..1//-2, %{t: :range, first: 10, last: 1, step: -2}},
          {1..10//2, %{t: :range, first: 1, last: 10, step: 2}},
          {1..0//1, %{t: :range, first: 1, last: 0, step: 1}},
          {1..1_000_000_000_000, %{t: :range, first: 1, last: 1_000_000_000_000, step: 1}}
        ] do
      changeset = validate(:inclusion, :integer, -1, range)
      assert_enum_payload(changeset, :inclusion, expected)
    end
  end

  test "preserves descending and empty date ranges" do
    for {range, expected} <- [
          {Date.range(~D[2026-10-10], ~D[2026-10-01], -2),
           %{t: :date_range, first: "2026-10-10", last: "2026-10-01", step: -2}},
          {Date.range(~D[2026-10-10], ~D[2026-10-01], 1),
           %{t: :date_range, first: "2026-10-10", last: "2026-10-01", step: 1}}
        ] do
      changeset = validate(:inclusion, :date, ~D[2026-10-11], range)
      assert_enum_payload(changeset, :inclusion, expected)
    end
  end

  test "preserves candidate list order and supports empty sets" do
    for {candidates, expected} <- [{[9, 1, 5], [9, 1, 5]}, {MapSet.new(), []}] do
      changeset = validate(:inclusion, :integer, 11, candidates)
      assert_enum_payload(changeset, :inclusion, expected)
    end
  end

  test "normalizes validation metadata even when the field classification is overridden" do
    changeset =
      Changeset.change({%{}, %{value: :integer}})
      |> RintoError.Changeset.add_error(:value, :out_of_bounds,
        validation: :inclusion,
        enum: 1..10
      )

    assert_enum_payload(changeset, :out_of_bounds, %{t: :range, first: 1, last: 10, step: 1})
  end

  test "preserves caller data and unrelated custom enum metadata" do
    for candidates <- [
          1..10,
          MapSet.new([1, 2]),
          {:custom, 1},
          [Duration.new!(day: 1)],
          [Decimal.new("1.0")]
        ] do
      changeset =
        Changeset.change({%{}, %{value: :integer}})
        |> Changeset.add_error(:value, "custom", validation: :custom, enum: candidates)

      error = %{Error.exception(changeset) | data: %{enum: candidates}}
      payload = Error.to_payload(error)

      assert payload.data == %{enum: candidates}
      assert [%{data: %{enum: ^candidates}}] = payload.errors
      assert error.raw == changeset
    end
  end

  defp validate(validation, type, value, candidates) do
    changeset = Changeset.cast({%{}, %{value: type}}, %{value: value}, [:value])

    case validation do
      :inclusion -> Changeset.validate_inclusion(changeset, :value, candidates)
      :subset -> Changeset.validate_subset(changeset, :value, candidates)
      :exclusion -> Changeset.validate_exclusion(changeset, :value, candidates)
    end
  end

  defp assert_enum_payload(changeset, kind, expected_enum) do
    refute changeset.valid?
    assert [value: original_error] = changeset.errors

    error = Error.exception(changeset)
    payload = Error.to_payload(error)

    assert payload.errors == [
             %{kind: kind, data: %{path: ["value"], enum: expected_enum}, errors: []}
           ]

    assert error.raw == changeset
    assert [field] = RintoError.Changeset.to_errors(changeset)
    assert Keyword.fetch!(error.raw.errors, :value) == original_error
    assert field == hd(payload.errors)

    encoded = Jason.encode!(error)
    assert encoded == Jason.encode!(payload)

    assert hd(Jason.decode!(encoded)["errors"])["data"]["enum"] ==
             Jason.decode!(Jason.encode!(expected_enum))

    if Code.ensure_loaded?(JSON) do
      assert apply(JSON, :encode!, [error]) == apply(JSON, :encode!, [payload])
    end
  end
end
