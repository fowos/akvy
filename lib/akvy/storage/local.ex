defmodule Akvy.Storage.Local do
  @moduledoc """
  Filesystem storage adapter used in tests and local experiments.
  """
  @behaviour Akvy.Storage

  @impl true
  def put_file(key, path, _opts) do
    dest = full_path(key)
    File.mkdir_p!(Path.dirname(dest))

    case File.cp(path, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download_to(key, path) do
    case File.cp(full_path(key), path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stream(key) do
    path = full_path(key)

    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, File.stream!(path, 64 * 1024), size}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case File.rm(full_path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ensure_bucket do
    File.mkdir_p!(root())
    :ok
  end

  @doc "Returns true when the object exists (test helper)."
  @spec exists?(Akvy.Storage.key()) :: boolean()
  def exists?(key), do: File.exists?(full_path(key))

  @doc "Filesystem path of the object under the configured `:root`."
  @spec full_path(Akvy.Storage.key()) :: Path.t()
  def full_path(key), do: Path.join(root(), key)

  @spec root() :: Path.t()
  defp root, do: Keyword.fetch!(Akvy.Storage.config(), :root)
end
