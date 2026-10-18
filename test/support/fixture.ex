defmodule RintoError.Fixture.Error do
  @moduledoc false

  use RintoError

  catalog do
    entry :missing, http_status: 404
    entry :broken, as: :unavailable, http_status: 500
    entry :local
    entry :silent
    entry_for Ecto.Changeset, :changeset_error, http_status: 422
  end
end

defmodule RintoError.Fixture.ConfiguredError do
  @moduledoc false

  use RintoError, inspect_opts: [limit: 2]
end

defmodule RintoError.Fixture.EmptyInspectOptionsError do
  @moduledoc false

  use RintoError, inspect_opts: []
end

defmodule RintoError.Fixture.FieldKindError do
  @moduledoc false

  use RintoError

  catalog do
    entry :required, as: :authentication_required, http_status: 401
    entry :length, as: :operation_limit
    entry :parent, as: :public_parent
    entry_for Ecto.Changeset, :invalid, as: :invalid_input, http_status: 422
  end
end
