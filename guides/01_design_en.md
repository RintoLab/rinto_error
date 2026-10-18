# 1. Design and error model

## Start with an application vocabulary

A payment provider may fail with a timeout, a vendor-specific response, or an unexpected value. Your application needs a stable way to describe the failure without making every caller understand that provider.

RintoError lets an application define its own Error module and catalog. The catalog is the set of internal kinds that the application accepts. The library supplies construction, payload conversion, and exception formatting; the application owns the meaning of its errors.

```elixir
defmodule MyApp.Error do
  use RintoError

  catalog do
    entry :payment_timeout, as: :payment_unavailable, http_status: 503
    entry :payment_rejected, as: :payment_unavailable, http_status: 502
    entry :reconciliation_failed
  end
end
```

Here, business code can distinguish `:payment_timeout` from `:payment_rejected`, while a client sees `:payment_unavailable` for both. An internal reconciliation error can exist without an HTTP status.

## Keep three decisions separate

1. **What happened?** The stored `kind` belongs to the application's catalog.
2. **What do we publish?** `as:` optionally maps that kind to an output name. A payload contains only `kind`, `data`, and `errors`.
3. **How does a transport respond?** `http_status:` optionally supplies an HTTP status. Payload conversion also works for RPC, queues, and other consumers.

An output name is not automatically a constructable kind. Mapping happens once, and the status is looked up using the stored internal kind. This lets the application evolve its internal classifications while deliberately maintaining its public vocabulary.

## Give each field a purpose

| Field | Intended role | In the public payload? |
| --- | --- | --- |
| `kind` | Internal classification | Yes, after optional mapping |
| `data` | Structured information for consumers | Yes |
| `errors` | Details owned by the caller or source | Yes |
| `raw` | Original failure or diagnostic value | No |
| `message` | Human-readable diagnostic text | No |
| `metadata` | Context, including the origin recorded by `new` | No |
| `__source__` | Registered source selector for conversion | No |

These are output boundaries, not automatic redaction. Anything you put in `data` or `errors`, or return from a source converter, may become public. Default exception text includes `data`, `errors`, and `metadata` as well as the kind and message.

## Construct now, convert at the boundary

For a registered struct, `build/1` translates the source into Error attributes. Later, the protocol function `to_payload/2` translates the complete Error into public data and details, using its first argument only to select the source type. Both protocol functions must be implemented. Construction does not run conversion; a source used only for exceptions and logs may explicitly reject public output.

The original struct does not have to live in `raw`. The builder chooses what to retain. At output time, `__source__` selects conversion; the type of `raw` does not.

The `errors` list is not an automatically traversed tree of business Errors. A source defines its own detail format. The library does not apply catalog aliases or recursively convert those details. The Ecto adapter, for example, produces field details with paths.

## Choose policy in the application

RintoError does not choose your business kinds, turn every failure into HTTP 500, emit logs, or install a Phoenix error handler. Expected failures can travel as `{:error, error}`; the same Error is also an exception when raising is appropriate. Keep these decisions at the application boundary and use the catalog to make the shared vocabulary explicit.

---

[中文](01_design_cn.md) · [Next: Define and use application errors](02_application_errors_en.md)
