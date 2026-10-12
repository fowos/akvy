defmodule AkvyWeb.Gettext do
  @moduledoc "Gettext backend; use with `use Gettext, backend: AkvyWeb.Gettext`."
  use Gettext.Backend, otp_app: :akvy
end
