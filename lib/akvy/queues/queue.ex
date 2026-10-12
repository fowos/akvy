defmodule Akvy.Queues.Queue do
  @moduledoc """
  A conversion queue: an ffmpeg command template plus limits and retention policy.

  `ffmpeg_args` is a template with `{input}` and `{output}` placeholders, e.g.
  `-i {input} -c:v libx264 -crf 23 -c:a aac {output}`.
  """
  use Akvy.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          ffmpeg_args: String.t() | nil,
          output_extension: String.t() | nil,
          output_content_type: String.t(),
          max_file_size_bytes: pos_integer(),
          allowed_content_types: [String.t()],
          result_ttl_seconds: pos_integer(),
          max_attempts: pos_integer(),
          timeout_seconds: pos_integer(),
          log_retention_days: pos_integer(),
          enabled: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "queues" do
    field :name, :string
    field :description, :string
    field :ffmpeg_args, :string
    field :output_extension, :string
    field :output_content_type, :string, default: "application/octet-stream"
    field :max_file_size_bytes, :integer, default: 1024 * 1024 * 1024
    field :allowed_content_types, {:array, :string}, default: []
    field :result_ttl_seconds, :integer, default: 24 * 60 * 60
    field :max_attempts, :integer, default: 3
    field :timeout_seconds, :integer, default: 30 * 60
    field :log_retention_days, :integer, default: 7
    field :enabled, :boolean, default: true

    timestamps()
  end

  @fields ~w(name description ffmpeg_args output_extension output_content_type max_file_size_bytes
             allowed_content_types result_ttl_seconds max_attempts timeout_seconds log_retention_days
             enabled)a

  @required ~w(name ffmpeg_args output_extension output_content_type max_file_size_bytes
               result_ttl_seconds max_attempts timeout_seconds log_retention_days)a

  @doc "Casts and validates editable fields; normalizes the extension and content type list."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(queue, attrs) do
    queue
    |> cast(attrs, @fields)
    |> update_change(:output_extension, &normalize_extension/1)
    |> update_change(:allowed_content_types, &normalize_list/1)
    |> validate_required(@required)
    |> validate_length(:name, max: 120)
    |> validate_format(:output_extension, ~r/^[a-z0-9]{1,10}$/,
      message: "must be 1-10 lowercase letters or digits"
    )
    |> validate_number(:max_file_size_bytes, greater_than: 0)
    |> validate_number(:result_ttl_seconds, greater_than: 0)
    |> validate_number(:max_attempts, greater_than: 0, less_than_or_equal_to: 20)
    |> validate_number(:timeout_seconds, greater_than: 0)
    |> validate_number(:log_retention_days, greater_than: 0)
    |> validate_ffmpeg_args()
    |> unique_constraint(:name)
  end

  @spec validate_ffmpeg_args(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_ffmpeg_args(changeset) do
    validate_change(changeset, :ffmpeg_args, fn :ffmpeg_args, args ->
      case Akvy.FFmpeg.parse_template(args) do
        {:ok, _argv} -> []
        {:error, message} -> [ffmpeg_args: message]
      end
    end)
  end

  @spec normalize_extension(String.t() | nil) :: String.t() | nil
  defp normalize_extension(nil), do: nil

  defp normalize_extension(ext),
    do: ext |> String.trim() |> String.trim_leading(".") |> String.downcase()

  @spec normalize_list([String.t()] | nil) :: [String.t()]
  defp normalize_list(nil), do: []

  defp normalize_list(list),
    do: list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  @doc """
  Returns true when the content type is allowed by the queue. Supports `type/*`
  patterns; an empty list allows everything.
  """
  @spec content_type_allowed?(t(), String.t() | nil) :: boolean()
  def content_type_allowed?(%__MODULE__{allowed_content_types: []}, _content_type), do: true

  def content_type_allowed?(%__MODULE__{allowed_content_types: allowed}, content_type) do
    content_type = content_type |> to_string() |> String.downcase()

    Enum.any?(allowed, fn pattern ->
      pattern = String.downcase(pattern)

      case String.split(pattern, "/") do
        [major, "*"] -> String.starts_with?(content_type, major <> "/")
        _ -> pattern == content_type
      end
    end)
  end
end
