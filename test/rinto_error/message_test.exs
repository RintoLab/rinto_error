defmodule RintoError.MessageTest do
  use ExUnit.Case, async: false

  alias RintoError.Fixture.{ConfiguredError, EmptyInspectOptionsError, Error}

  setup do
    original = Application.fetch_env(:rinto_error, :inspect_opts)
    Application.delete_env(:rinto_error, :inspect_opts)

    on_exit(fn ->
      case original do
        {:ok, opts} -> Application.put_env(:rinto_error, :inspect_opts, opts)
        :error -> Application.delete_env(:rinto_error, :inspect_opts)
      end
    end)
  end

  test "application options are read at runtime and preserve unspecified defaults" do
    error = %Error{raw: :private, kind: :broken, message: "abcdefgh", data: %{items: [1, 2, 3]}}

    assert Exception.message(error) =~ ~s(message: "abcdefgh")

    Application.put_env(:rinto_error, :inspect_opts, printable_limit: 4)
    text = Exception.message(error)
    assert text =~ ~s(message: "abcd" <> ...)
    assert text =~ "items: [1, 2, 3]"

    Application.put_env(:rinto_error, :inspect_opts, [])
    assert Exception.message(error) =~ ~s(message: "abcdefgh")
  end

  test "module options override application options and limit error details" do
    Application.put_env(:rinto_error, :inspect_opts, limit: 3, printable_limit: 4)

    error = %ConfiguredError{
      raw: :private,
      kind: :broken,
      message: "abcdefgh",
      data: %{items: [1, 2, 3]},
      errors: [%{field: :name}, %{field: :age}, %{field: :email}]
    }

    text = Exception.message(error)

    assert text =~ "items: [1, ...]"
    assert text =~ ~s(message: "abcd" <> ...)
    # Nested truncation text varies across Elixir versions; assert the configured limit.
    assert "  errors: #{inspect(error.errors, limit: 2)}" in String.split(text, "\n")
    refute text =~ ":private"

    ordinary = %Error{raw: :private, kind: :broken, data: error.data, errors: error.errors}
    ordinary_text = Exception.message(ordinary)
    assert ordinary_text =~ "items: [1, 2, ...]"
    assert "  errors: #{inspect(error.errors, limit: 3)}" in String.split(ordinary_text, "\n")
  end

  test "formats ordinary error details in field order without exposing private fields" do
    error = %Error{
      raw: :private,
      kind: :broken,
      __source__: Ecto.Changeset,
      message: "invalid input",
      data: %{request_id: 1},
      errors: [%{name: :required}],
      metadata: %{origin: :test}
    }

    assert Exception.message(error) == """
           RintoError.Fixture.Error
             kind: :broken
             message: "invalid input"
             data: %{request_id: 1}
             errors: [%{name: :required}]
             metadata: %{origin: :test}\
           """
  end

  test "module options work without application configuration" do
    error = %ConfiguredError{
      raw: :private,
      kind: :broken,
      message: String.duplicate("x", 5_000),
      data: %{items: [1, 2, 3]}
    }

    text = Exception.message(error)
    assert text =~ "items: [1, ...]"
    assert text =~ error.message
  end

  test "empty module options inherit application options" do
    Application.put_env(:rinto_error, :inspect_opts, printable_limit: 4)
    error = %EmptyInspectOptionsError{raw: :private, kind: :broken, message: "abcdefgh"}

    assert Exception.message(error) =~ ~s(message: "abcd" <> ...)
  end

  test "users can override message for logging and raised exceptions or call super" do
    alias RintoError.Fixture.CustomMessageError
    require Logger
    import ExUnit.CaptureLog

    error = CustomMessageError.exception(raw: :private, kind: :broken, message: "detail")
    assert Exception.message(error) == "custom broken: detail"

    assert capture_log(fn -> Logger.error(Exception.message(error)) end) =~
             "custom broken: detail"

    assert_raise CustomMessageError, "custom broken: detail", fn -> raise error end
    assert Exception.message(%{error | message: "default"}) =~ "kind: :broken"
  end
end
