defmodule Akvy.Storage.S3 do
  @moduledoc """
  S3-compatible storage (RustFS, MinIO, AWS S3) via ExAws with the Req HTTP client.
  Uploads use multipart upload, downloads use parallel ranged GETs.
  """
  @behaviour Akvy.Storage

  alias ExAws.S3

  @impl true
  def put_file(key, path, opts) do
    content_type = Keyword.get(opts, :content_type) || "application/octet-stream"

    path
    |> S3.Upload.stream_file()
    |> S3.upload(bucket(), key, content_type: content_type)
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download_to(key, path) do
    case bucket() |> S3.download_file(key, path) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def stream(key) do
    case bucket() |> S3.head_object(key) |> ExAws.request() do
      {:ok, %{headers: headers}} ->
        size = headers |> header("content-length") |> String.to_integer()

        stream =
          bucket()
          |> S3.download_file(key, :memory, chunk_size: 4 * 1024 * 1024)
          |> ExAws.stream!()

        {:ok, stream, size}

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case bucket() |> S3.delete_object(key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ensure_bucket do
    case bucket() |> S3.head_bucket() |> ExAws.request() do
      {:ok, _} ->
        :ok

      {:error, {:http_error, 404, _}} ->
        region = Application.get_env(:ex_aws, :s3, [])[:region] || "us-east-1"

        case bucket() |> S3.put_bucket(region) |> ExAws.request() do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec header([{String.t(), String.t() | [String.t()]}], String.t()) :: String.t()
  defp header(headers, name) do
    Enum.find_value(headers, "0", fn {k, v} ->
      if String.downcase(k) == name, do: v |> List.wrap() |> List.first()
    end)
  end

  defp bucket, do: Keyword.fetch!(Akvy.Storage.config(), :bucket)
end
