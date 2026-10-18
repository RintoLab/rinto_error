# 3. Ecto 校验错误实践

Elixir 应用使用 Ecto 进行数据库操作时，校验失败经常以 `{:error, %Ecto.Changeset{}}` 返回。本篇说明如何把这样的结果接入统一的应用 Error，同时保留字段级错误，供调用方和前端处理。

## 显式注册 changeset

本篇假定应用已经使用 Ecto。RintoError 的 Ecto 支持是可选的，库编译时存在 Ecto、且配置未排除默认实现时，会提供标准的 `RintoError.Source` 实现。

Ecto changeset 需要在 Error 模块中显式注册，并明确选择业务 kind 和公开名称：

```elixir
defmodule MyApp.Error do
  use RintoError

  catalog do
    entry_for Ecto.Changeset, :checkout_invalid,
      as: :invalid_input,
      http_status: 422
  end
end
```

默认 handler 在构造阶段将 changeset 存入 `raw`，请求输出时才展开字段错误：

```elixir
require MyApp.Error, as: Error

changeset =
  Ecto.Changeset.change({%{}, %{email: :string}})
  |> Ecto.Changeset.validate_required([:email])

error = Error.new(changeset)
Error.to_payload(error)
# %{
#   kind: :invalid_input,
#   data: %{},
#   errors: [%{kind: :required, data: %{path: ["email"]}, errors: []}]
# }
Error.http_status(error) # 422
```

在数据库操作中，`{:error, changeset}` 返回的 changeset 也可以这样传给 `MyApp.Error.new/1`。是在业务 context 边界包装，还是保留 changeset 继续返回，由应用决定。

## 区分业务失败和字段详情

外层 `:checkout_invalid` 属于 catalog，会映射成 `:invalid_input`。字段分类，例如 `:required`、`:cast` 和 `:length`，不需要在 catalog 中声明，也不会被该 catalog 重命名。

嵌套 association 和 embed 会生成字段路径。例如 `["items", 0, "name"]` 表示第一项的 `name`，列表下标从零开始。适配器返回扁平的字段 payload 列表，每项的 `errors` 为 `[]`，而不是嵌套的应用 Error struct。

Ecto 原始错误消息保留在 raw changeset 中。公开详情携带分类和结构化元数据，消费者可以据此选择自己的文案。

## 添加领域特有的字段分类

```elixir
changeset =
  Ecto.Changeset.change({%{}, %{coupon: :string}})
  |> RintoError.Changeset.add_error(:coupon, :expired, message: "Coupon expired")

RintoError.Changeset.to_errors(changeset)
# [%{kind: :expired, data: %{path: ["coupon"]}, errors: []}]
```

分类必须是除 `nil`、`true`、`false` 之外的 atom。`add_error/4` 和 `to_errors/1` 也可以独立使用，不依赖 Error 模块或 source 注册。

## 理解结构化校验元数据

这些数据适合前端对接：前端可以用 `data.path` 定位表单字段，根据字段 `kind` 选择错误文案，再结合类型和校验参数展示提示或本地化信息，无需解析后端的错误字符串。例如，`kind: :required` 配合路径 `["email"]`，即可在邮箱输入框旁展示必填提示。

字段元数据包含类型时，`data.type` 使用 `t` 作为类型标识：

| 含义 | 示例 |
| --- | --- |
| 整数 | `%{t: :integer}` |
| UUID | `%{t: :uuid}` |
| 整数数组 | `%{t: :array, of: %{t: :integer}}` |
| 枚举 | `%{t: :enum, values: ["reader", "editor"]}` |

类型信息需要结合字段 kind 理解：cast 错误描述期望类型，length 错误描述被计数的对象。列表长度错误不会推断元素类型，没有类型元数据的字段也不会新增 type 字段。

适配器还会描述支持的校验值，例如 inclusion 校验中的 range、number 校验中的 decimal 边界。完整约定见 `RintoError.Changeset`。这不是对所有应用数据做通用 JSON 规范化，原始元数据仍保留在 raw changeset 中。

## 替换库提供的协议实现

Changeset 就是自定义 struct 扩展机制的一个示例：通过 `defimpl RintoError.Source` 实现 `build/1` 和 `to_payload/2`。构造和输出都走协议分派，Error 模块中没有 Changeset 专用路由。使用默认行为只需注册类型。

如果不喜欢默认行为，可以在库编译时排除它，再在应用的 `lib/` 中定义自己的实现：

```elixir
# config/config.exs — before compiling :rinto_error
import Config
config :rinto_error, exclude_default_sources: [Ecto.Changeset]
```

```elixir
# lib/my_app/changeset_source.ex
defimpl RintoError.Source, for: Ecto.Changeset do
  @impl true
  def build(changeset), do: %{raw: changeset}

  @impl true
  def to_payload(_source, error) do
    %{
      data: %{form: "checkout"},
      errors: RintoError.Changeset.to_errors(error.raw)
    }
  end
end

defmodule MyApp.CheckoutError do
  use RintoError

  catalog do
    entry_for Ecto.Changeset, :checkout_invalid, as: :invalid_input, http_status: 422
  end
end
```

如果依赖之前已经编译过，修改配置后执行：

```sh
mix deps.compile rinto_error --force
mix compile
```

这是编译期的应用配置，不是 `use RintoError` 的选项，也不能作为运行时开关。排除后，库不会定义该协议实现，但仍保留 Ecto 支持和 `RintoError.Changeset` 工具函数。若未提供替代实现，注册 Ecto 时会触发构建校验失败。用户实现会对所有注册了 `Ecto.Changeset` 的 Error 模块生效。每种 source 类型只能有一个实现，并且必须在协议 consolidation 前编译；如果需要多种行为并存，应定义包装 struct 及其独立实现。

`to_payload/2` 的第一个参数是用于类型分派的空 Changeset，并非原始输入；转换应读取第二个参数中的当前 Error。显式 Error data 优先于转换返回的数据，因此已有的 `error.data.form` 会覆盖 `"checkout"`。返回的字段详情替换已有的 `error.errors`。应用侧输出接口仍然是 `MyApp.CheckoutError.to_payload(error)`。

---

[English](03_ecto_en.md) · [上一篇: 定义与使用应用错误](02_application_errors_cn.md) · [下一篇: 接入自定义错误 struct](04_custom_structs_cn.md)
