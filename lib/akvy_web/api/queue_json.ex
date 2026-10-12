defmodule AkvyWeb.Api.QueueJSON do
  @moduledoc "Renders queues for the client API."
  alias Akvy.Queues.Queue

  @type queue_json :: %{
          id: UUIDv7.t(),
          name: String.t(),
          description: String.t() | nil,
          output_extension: String.t(),
          output_content_type: String.t(),
          max_file_size_bytes: pos_integer(),
          allowed_content_types: [String.t()],
          result_ttl_seconds: pos_integer()
        }

  @doc "Renders a list of queues."
  @spec index(%{queues: [Queue.t()]}) :: %{data: [queue_json()]}
  def index(%{queues: queues}), do: %{data: Enum.map(queues, &data/1)}

  @doc "Renders a single queue."
  @spec data(Queue.t()) :: queue_json()
  def data(%Queue{} = queue) do
    %{
      id: queue.id,
      name: queue.name,
      description: queue.description,
      output_extension: queue.output_extension,
      output_content_type: queue.output_content_type,
      max_file_size_bytes: queue.max_file_size_bytes,
      allowed_content_types: queue.allowed_content_types,
      result_ttl_seconds: queue.result_ttl_seconds
    }
  end
end
