defmodule Akvy.Storage do
  @moduledoc """
  Object storage facade. The adapter is configured with:

      config :akvy, Akvy.Storage, adapter: Akvy.Storage.S3, bucket: "akvy"
  """

  @typedoc "Object key within the bucket, e.g. `inputs/<task_id>`."
  @type key :: String.t()

  @type put_option :: {:content_type, String.t() | nil}

  @doc "Uploads a local file under `key`."
  @callback put_file(key :: key(), path :: Path.t(), opts :: [put_option()]) ::
              :ok | {:error, term()}
  @doc "Downloads the object to a local path."
  @callback download_to(key :: key(), path :: Path.t()) :: :ok | {:error, term()}
  @doc "Returns a chunked stream of the object and its size in bytes; `{:error, :not_found}` if missing."
  @callback stream(key :: key()) ::
              {:ok, Enumerable.t(binary()), size :: non_neg_integer()} | {:error, term()}
  @doc "Deletes the object; a missing object is not an error."
  @callback delete(key :: key()) :: :ok | {:error, term()}
  @doc "Creates the bucket (or root directory) if it does not exist."
  @callback ensure_bucket() :: :ok | {:error, term()}

  @doc "Uploads a local file under `key`."
  @spec put_file(key(), Path.t(), [put_option()]) :: :ok | {:error, term()}
  def put_file(key, path, opts \\ []), do: adapter().put_file(key, path, opts)
  @doc "Downloads the object to a local path."
  @spec download_to(key(), Path.t()) :: :ok | {:error, term()}
  def download_to(key, path), do: adapter().download_to(key, path)
  @doc "Returns a chunked stream of the object and its size in bytes."
  @spec stream(key()) :: {:ok, Enumerable.t(binary()), non_neg_integer()} | {:error, term()}
  def stream(key), do: adapter().stream(key)
  @doc "Deletes the object; succeeds if it does not exist."
  @spec delete(key()) :: :ok | {:error, term()}
  def delete(key), do: adapter().delete(key)
  @doc "Creates the bucket if it does not exist."
  @spec ensure_bucket() :: :ok | {:error, term()}
  def ensure_bucket, do: adapter().ensure_bucket()

  @doc "Returns the `Akvy.Storage` application config."
  @spec config() :: keyword()
  def config, do: Application.get_env(:akvy, __MODULE__, [])

  defp adapter, do: Keyword.fetch!(config(), :adapter)
end
