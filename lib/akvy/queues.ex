defmodule Akvy.Queues do
  @moduledoc """
  Management of conversion queues.
  """
  import Ecto.Query

  alias Akvy.Repo
  alias Akvy.Queues.Queue

  @doc "Lists all queues ordered by name."
  @spec list_queues() :: [Queue.t()]
  def list_queues do
    Repo.all(from q in Queue, order_by: q.name)
  end

  @doc "Lists enabled queues ordered by name."
  @spec list_enabled_queues() :: [Queue.t()]
  def list_enabled_queues do
    Repo.all(from q in Queue, where: q.enabled, order_by: q.name)
  end

  @doc "Fetches a queue by id. Raises `Ecto.NoResultsError` if not found."
  @spec get_queue!(UUIDv7.t()) :: Queue.t()
  def get_queue!(id), do: Repo.get!(Queue, id)

  @doc "Fetches a queue by id, returning nil for unknown or malformed ids."
  @spec get_queue(term()) :: Queue.t() | nil
  def get_queue(id) do
    case UUIDv7.cast(id) do
      {:ok, id} -> Repo.get(Queue, id)
      :error -> nil
    end
  end

  @doc "Creates a queue."
  @spec create_queue(map()) :: {:ok, Queue.t()} | {:error, Ecto.Changeset.t()}
  def create_queue(attrs) do
    %Queue{}
    |> Queue.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a queue."
  @spec update_queue(Queue.t(), map()) :: {:ok, Queue.t()} | {:error, Ecto.Changeset.t()}
  def update_queue(%Queue{} = queue, attrs) do
    queue
    |> Queue.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a queue. Returns a changeset error while tasks still reference it."
  @spec delete_queue(Queue.t()) :: {:ok, Queue.t()} | {:error, Ecto.Changeset.t()}
  def delete_queue(%Queue{} = queue) do
    queue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :tasks_queue_id_fkey,
      message: "queue has tasks, disable it instead"
    )
    |> Repo.delete()
  end

  @doc "Returns a changeset for tracking queue changes."
  @spec change_queue(Queue.t(), map()) :: Ecto.Changeset.t()
  def change_queue(%Queue{} = queue, attrs \\ %{}) do
    Queue.changeset(queue, attrs)
  end
end
