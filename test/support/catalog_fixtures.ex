defmodule RintoError.Fixture.CatalogOptions do
  @moduledoc false
  use RintoError

  catalog do
    entry :local
    entry :missing, http_status: 404, doc: "Record not found"
    entry :broken, as: :unavailable, doc: "上游不可用\n供排查参考"
    entry :timeout, as: :unavailable, http_status: 503, doc: ""
  end
end

defmodule RintoError.Fixture.OutputMapping do
  @moduledoc false
  use RintoError

  catalog do
    entry :alpha, as: :beta, http_status: 500
    entry :beta, as: :gamma, http_status: 503
    entry :local, as: :beta
    entry :self, as: :self
  end
end

defmodule RintoError.Fixture.EmptyCatalog do
  @moduledoc false
  use RintoError

  catalog do
  end
end

defmodule RintoError.Fixture.NoCatalog do
  @moduledoc false
  use RintoError
end

defmodule RintoError.Fixture.StatusBounds do
  @moduledoc false
  use RintoError

  catalog do
    entry :low, as: :shared, http_status: 100
    entry :high, as: :shared, http_status: 599
  end
end

defmodule RintoError.Fixture.ChangesetOutput do
  @moduledoc false
  use RintoError

  catalog do
    entry_for Ecto.Changeset, :changeset_error, as: :rejected, http_status: 422
  end
end

defmodule RintoError.Fixture.CustomChangesetKind do
  @moduledoc false
  use RintoError

  catalog do
    entry :changeset_error, as: :business_error, http_status: 409

    entry_for Ecto.Changeset, :validation_error,
      as: :invalid_input,
      http_status: 422,
      doc: "输入校验失败"
  end
end

defmodule RintoError.Fixture.MinimalChangesetConfig do
  @moduledoc false
  use RintoError

  catalog do
    entry :changeset_error, http_status: 409
    entry_for Ecto.Changeset, :validation_error
  end
end
