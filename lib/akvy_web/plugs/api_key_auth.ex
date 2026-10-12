defmodule AkvyWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates client applications with `Authorization: Bearer <api key>`.

  With `allow_query: true` the key may also be passed as `?api_key=...`, because
  browser `EventSource` cannot set request headers. Use it only for SSE routes.
  """
  @behaviour Plug

  import Plug.Conn

  alias Akvy.ApiKeys

  @impl true
  def init(opts), do: Keyword.get(opts, :allow_query, false)

  @impl true
  def call(conn, allow_query?) do
    case ApiKeys.authenticate(token(conn, allow_query?)) do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_resp(401, Jason.encode!(%{errors: %{detail: "Unauthorized"}}))
        |> halt()

      api_key ->
        assign(conn, :api_key, api_key)
    end
  end

  @spec token(Plug.Conn.t(), boolean()) :: String.t() | nil
  defp token(conn, allow_query?) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        String.trim(token)

      _ when allow_query? ->
        conn = fetch_query_params(conn)
        conn.query_params["api_key"]

      _ ->
        nil
    end
  end
end
