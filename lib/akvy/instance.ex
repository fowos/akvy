defmodule Akvy.Instance do
  @moduledoc """
  Identity of the running service instance.

  Several instances may run on the same host (or with the same unnamed BEAM node),
  so the id is `INSTANCE_NAME` when set, otherwise the Erlang node name when the
  node is distributed, otherwise `<hostname>-<random suffix>` generated once at boot.
  It is recorded in task events and used as the Oban node.
  """

  @key {__MODULE__, :id}

  @doc "Initializes the instance id. Called once from `Akvy.Application`."
  @spec init() :: String.t()
  def init do
    id =
      case System.get_env("INSTANCE_NAME") do
        name when name in [nil, ""] and node() != :nonode@nohost ->
          Atom.to_string(node())

        name when name in [nil, ""] ->
          {:ok, host} = :inet.gethostname()
          suffix = Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
          "#{host}-#{suffix}"

        name ->
          name
      end

    :persistent_term.put(@key, id)
    id
  end

  @doc "Returns the instance id, initializing it on first call."
  @spec id() :: String.t()
  def id do
    case :persistent_term.get(@key, nil) do
      nil -> init()
      id -> id
    end
  end
end
