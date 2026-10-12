defmodule AkvyWeb.ErrorHTML do
  @moduledoc "Renders HTML error pages for the endpoint (see `config/config.exs`)."
  use AkvyWeb, :html

  # If you want to customize your error pages,
  # uncomment the embed_templates/1 call below
  # and add pages to the error directory:
  #
  #   * lib/akvy_web/controllers/error_html/404.html.heex
  #   * lib/akvy_web/controllers/error_html/500.html.heex
  #
  # embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  @doc "Renders the status message for `template`, e.g. `\"404.html\"` -> `\"Not Found\"`."
  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
