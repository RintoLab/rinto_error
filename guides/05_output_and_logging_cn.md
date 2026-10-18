# 5. 输出、日志与应用边界

## 决定哪些信息跨越边界

本篇使用“定义与使用应用错误”中的 `MyApp.Error` catalog。基于 source 的 Error 也使用相同的边界 API，只是在输出时先由 converter 提供数据和详情。

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

诊断消息、原始支付服务返回值、metadata 和 source selector 都不会进入 payload。这些字段的省略不会对 `data` 或 `errors` 自动脱敏，因此只应发布消费者需要的信息。外层 `kind` 在编码器处理之前仍是 atom。

## 在 HTTP 边界适配 HTTP

```elixir
defmodule MyApp.ErrorResponse do
  alias MyApp.Error

  def from_error(%Error{} = error) do
    {Error.http_status(error), Error.to_payload(error)}
  end
end
```

Controller 或传输适配层可以用这个 tuple 设置响应状态并编码响应体。RintoError 不依赖 Web 框架，也不会自行发送响应。

状态取自存储的内部 kind，即使多个 kind 共用公开名称也是如此。没有配置状态时，`http_status/1` 会抛出 `ArgumentError`，不会默认返回 400 或 500。应为进入这个 HTTP 适配层的错误配置状态，或者在应用中制定另外的明确策略。缺少 HTTP 配置不妨碍为队列、RPC 或内部消费者生成 payload。

## 编码 payload

使用 Jason 显式编码 payload：

```elixir
Jason.encode!(MyApp.Error.to_payload(error))
```

Error 模块编译时，如果已加载 `Jason.Encoder` 或 `JSON.Encoder`，RintoError 会生成对应实现。有对应实现时，直接编码 `error` 也会调用 `to_payload/1`。每次编码都会重新进行 source 转换，不要依赖转换只执行一次。

库不会规范化应用 `data` 或自定义详情中的任意值，需要选择编码器支持的数据。对于 `__source__: nil` 的普通错误，data 和详情会按存储值输出。

## 在处理失败的位置记录日志

```elixir
require Logger
Logger.error(Exception.message(error))
```

库负责格式化文本，不会主动发出日志。日志级别和记录位置由应用选择；在处理边界统一记录，可以减少错误传递过程中产生的重复日志。

默认文本以 Error 模块名开头，之后依次是 kind、message、data、errors 和 metadata，省略 `raw` 和 `__source__`。通过 `new` 构造的 Error 会在 metadata 中包含构造位置。制定日志策略时也要考虑 metadata：不进入公开 payload，并不等于不会进入日志。

在最终 Error 模块中覆盖 `message/1`，可以定制异常和日志文本：

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

`super(error)` 复用默认格式化器。这会影响 `Exception.message/1` 和抛出异常时的格式，不影响 payload。Source converter 不控制这个 callback。

也可以全局配置字段值的 inspect 选项：

```elixir
config :rinto_error, inspect_opts: [width: 120, limit: 50, printable_limit: 2_000]
```

将它放入应用配置中。选项依次由内置默认值、应用配置、`use` 选项合并。应用配置在每次格式化时读取，模块选项在编译时捕获。这些选项不影响 `inspect(error)` 或 JSON 编码。

## 维护稳定的边界约定

测试消费者依赖的公开 kind、payload data、字段详情和状态。内部诊断文案可以独立演进。新增 source 时，通过 `MyApp.Error.to_payload/1` 验证公开输出，让测试同时覆盖 source 选择、数据合并和 kind 映射。

---

[English](05_output_and_logging_en.md) · [上一篇: 接入自定义错误 struct](04_custom_structs_cn.md)
