# 5. Output, logging, and application boundaries

## Decide what crosses the boundary

This guide uses the `MyApp.Error` catalog from “Define and use application errors.” A source-backed Error follows the same boundary API, with its converter supplying data and details first.

```elixir
require MyApp.Error, as: Error

error = Error.new(
  kind: :payment_timeout,
  raw: {:provider, :timeout},
  message: "Provider request timed out",
  data: %{order_id: "order-42"},
  metadata: %{request_id: "request-7"}
)

Error.to_payload(error)
# %{kind: :payment_unavailable, data: %{order_id: "order-42"}, errors: []}
Error.http_status(error) # 503
```

The diagnostic message, raw provider value, metadata, and source selector do not appear in the payload. These omissions do not sanitize `data` or `errors`; publish only values intended for consumers. The outer `kind` remains an atom until the encoder handles it.

## Adapt to HTTP where HTTP is used

```elixir
defmodule MyApp.ErrorResponse do
  alias MyApp.Error

  def from_error(%Error{} = error) do
    {Error.http_status(error), Error.to_payload(error)}
  end
end
```

A controller or transport adapter can use that tuple to set its response status and encode its body. RintoError has no dependency on a web framework and does not send the response itself.

The status comes from the stored internal kind, even when several kinds share a public name. If a kind has no status, `http_status/1` raises `ArgumentError`; it never assumes 400 or 500. Configure statuses for errors reaching this HTTP adapter, or make a separate explicit application policy for them. Missing HTTP configuration does not prevent payload conversion for a queue, RPC, or internal consumer.

## Encode the payload

Encode the explicit payload with Jason:

```elixir
Jason.encode!(MyApp.Error.to_payload(error))
```

When `Jason.Encoder` or `JSON.Encoder` is loaded while the Error module compiles, RintoError generates the corresponding implementation. With that implementation available, encoding `error` directly uses `to_payload/1` too. Each encoding performs source conversion again; do not rely on conversion running only once.

The library does not normalize arbitrary values in application `data` or custom details. Choose values supported by your encoder. For ordinary errors with `__source__: nil`, data and details are emitted as stored.

## Log where the failure is handled

```elixir
require Logger
Logger.error(Exception.message(error))
```

The library formats text but does not emit logs. Choose the level and logging location in the application; logging once at the handling boundary can avoid repeated messages while an error is propagated.

Default text starts with the Error module name, followed by kind, message, data, errors, and metadata. It omits `raw` and `__source__`. An Error built with `new` includes its recorded construction origin in metadata. Review metadata as part of your logging policy: exclusion from the public payload does not mean exclusion from logs.

Override `message/1` on the final Error module to customize exception and log text:

```elixir
defmodule MyApp.WorkerError do
  use RintoError, inspect_opts: [limit: 50, printable_limit: 2_000]

  catalog do
    entry :reconciliation_failed
  end

  @impl true
  def message(error) do
    "Reconciliation worker: " <> super(error)
  end
end
```

`super(error)` reuses the default formatter. This affects `Exception.message/1` and raised exception formatting, not payloads. Source converters do not control this callback.

You can configure inspected field values globally:

```elixir
config :rinto_error, inspect_opts: [width: 120, limit: 50, printable_limit: 2_000]
```

Put this in application configuration. Options merge from built-in defaults to application configuration to `use` options. Application configuration is read on every formatting call; module options are captured at compile time. These options affect neither `inspect(error)` nor JSON encoding.

## Keep the boundary contract stable

Test the public kind, payload data, field details, and status that consumers depend on. Internal diagnostic messages can change independently. When adding a source, exercise its public output through `MyApp.Error.to_payload/1` so tests cover source selection, data merging, and kind mapping together.

---

[中文](05_output_and_logging_cn.md) · [Previous: Integrate custom error structs](04_custom_structs_en.md)
