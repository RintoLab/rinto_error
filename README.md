# RintoError

[![Hex version](https://img.shields.io/hexpm/v/rinto_error.svg)](https://hex.pm/packages/rinto_error)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/rinto_error/)

Define your application's error vocabulary with a reusable Elixir error struct.
RintoError validates declared kinds, builds transport-independent public payloads,
and formats exception and log text. Public names and HTTP statuses are optional;
registered custom structs and Ecto changesets can supply their own error details.
Both use `defimpl RintoError.Source` with `build/1` and `to_payload/2` through
protocol dispatch. The supplied Changeset implementation can be excluded at
compile time so your application can provide its own (see the Ecto guide).

## Installation

Requires Elixir `~> 1.17`. Add RintoError to your dependencies and run `mix deps.get`:

```elixir
def deps do
  [
    {:rinto_error, "~> 0.1.0"}
  ]
end
```

Add `:rinto_error` to `import_deps` in `.formatter.exs` for catalog formatting:

```elixir
[
  import_deps: [:rinto_error]
]
```

## Minimal usage

### Return a business error

Declare only the kinds your application needs. Public names and HTTP statuses
are optional:

```elixir
defmodule MyApp.Error do
  use RintoError

  catalog do
    entry :payment_timeout
  end
end

defmodule MyApp.Payments do
  require MyApp.Error, as: Error

  def interpret_result({:ok, receipt}), do: {:ok, receipt}
  def interpret_result({:error, :timeout}), do: {:error, Error.new(:payment_timeout)}
end
```

The function returns an ordinary error tuple containing your Error struct, so
callers can match on its kind:

```elixir
{:error, %MyApp.Error{kind: :payment_timeout}} =
  MyApp.Payments.interpret_result({:error, :timeout})
```

`Error.new/1` validates the kind and records the construction location. This
example needs no HTTP or payload configuration and does not raise or log.

### Respond to an error in Phoenix

For an HTTP application, extend the catalog with an optional public name and
status (use this definition in place of the one above):

```elixir
defmodule MyApp.Error do
  use RintoError

  catalog do
    entry :payment_timeout, as: :payment_unavailable, http_status: 503
  end
end
```

In an existing Phoenix application, a fallback controller can turn the same
`{:error, error}` result into an HTTP response:

```elixir
defmodule MyAppWeb.FallbackController do
  use MyAppWeb, :controller
  alias MyApp.Error

  def call(conn, {:error, %Error{} = error}) do
    conn
    |> put_status(Error.http_status(error))
    |> json(Error.to_payload(error))
  end
end
```

Set `action_fallback MyAppWeb.FallbackController` in the calling controller and
return `{:error, error}` from its action. For the timeout above, the response has
status **503** and this JSON body:

```json
{"kind":"payment_unavailable","data":{},"errors":[]}
```

Business code still sees `:payment_timeout`; `as:` changes only the public name.
RintoError supplies the status and payload, while Phoenix sends the response.

## Guides / 使用指南

Read these guides in order, or jump to the integration you need. Each guide is
available in English and Chinese.

| Guide | English | 中文 |
| --- | --- | --- |
| 1. Design and error model | [English](guides/01_design_en.md) | [设计思想与错误模型](guides/01_design_cn.md) |
| 2. Application errors | [English](guides/02_application_errors_en.md) | [定义与使用应用错误](guides/02_application_errors_cn.md) |
| 3. Ecto validation | [English](guides/03_ecto_en.md) | [Ecto 校验错误实践](guides/03_ecto_cn.md) |
| 4. Custom error structs | [English](guides/04_custom_structs_en.md) | [接入自定义错误 struct](guides/04_custom_structs_cn.md) |
| 5. Output and logging | [English](guides/05_output_and_logging_en.md) | [输出、日志与应用边界](guides/05_output_and_logging_cn.md) |

For API contracts and options, see `RintoError`, `RintoError.Source`,
and `RintoError.Changeset` in the
[API documentation](https://hexdocs.pm/rinto_error/RintoError.html).

## License

MIT.
