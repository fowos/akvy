defmodule AkvyWeb.ErrorJSON do
  @moduledoc "Renders JSON error responses for the endpoint (see `config/config.exs`)."

  @type error_json :: %{errors: %{detail: String.t()}}

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  @doc "Renders the status message for `template`, e.g. `\"404.json\"`."
  @spec render(String.t(), map()) :: error_json()
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
