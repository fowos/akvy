defmodule Akvy.Accounts.User do
  @moduledoc """
  Admin panel user. Passwords are hashed with PBKDF2; `password` and
  `authenticated_at` are virtual.
  """
  use Akvy.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: UUIDv7.t() | nil,
          email: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          authenticated_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type email_option :: {:validate_unique, boolean()}
  @type password_option :: {:hash_password, boolean()}

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for registering or changing the email; the email must change.

  Option `validate_unique: false` skips the database uniqueness check (for live validation).
  """
  @spec email_changeset(t(), map(), [email_option()]) :: Ecto.Changeset.t(t())
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  @spec validate_email(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Akvy.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  @spec validate_email_changed(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  Changeset for setting the password (12 to 72 characters).

  Option `hash_password: false` keeps the plain password and skips hashing (for live validation).
  """
  @spec password_changeset(t() | Ecto.Changeset.t(t()), map(), [password_option()]) ::
          Ecto.Changeset.t(t())
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  @spec validate_password(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  @spec maybe_hash_password(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  @spec confirm_changeset(t() | Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc "Verifies the password; takes constant time even without a user."
  @spec valid_password?(t() | nil, String.t()) :: boolean()
  def valid_password?(%Akvy.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end
end
