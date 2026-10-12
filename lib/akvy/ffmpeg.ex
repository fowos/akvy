defmodule Akvy.FFmpeg do
  @moduledoc """
  Builds and runs ffmpeg commands.

  The queue template is split into argv with shell-like quoting rules
  (`OptionParser.split/1`) and executed directly — never through a shell.
  `{input}` and `{output}` placeholders are substituted with local file paths.

  The OS process is killed when the timeout expires, and also when the calling
  process dies (e.g. the Oban job was cancelled), via a small guardian process.
  """

  @default_args ["-nostdin", "-y", "-hide_banner", "-nostats"]

  @type argv :: [String.t()]

  @typedoc "Accumulator threaded through the `:on_line` callback."
  @type acc :: term()

  @type run_option ::
          {:timeout, timeout()}
          | {:on_line, (String.t(), acc() -> acc())}
          | {:acc, acc()}

  @type run_result ::
          {:ok, acc()}
          | {:error, {:exit_status, pos_integer()}, acc()}
          | {:error, :timeout | :not_found, acc()}

  @doc "Validates a template and returns its argv; errors are human-readable messages."
  @spec parse_template(term()) :: {:ok, argv()} | {:error, String.t()}
  def parse_template(template) when is_binary(template) do
    argv = OptionParser.split(template)

    cond do
      argv == [] ->
        {:error, "must not be empty"}

      not Enum.any?(argv, &String.contains?(&1, "{input}")) ->
         {:error, "must contain {input}"}

      not Enum.any?(argv, &String.contains?(&1, "{output}")) ->
        {:error, "must contain {output}"}

      List.first(argv) =~ ~r/^ffmpeg(\.exe)?$/i ->
        {:error, "must not include the ffmpeg binary"}

      true -> {:ok, argv}
    end
  end

  def parse_template(_), do: {:error, "must be a string"}

  @doc "Builds the final argv (default flags included) for the given template and file paths."
  @spec build_argv(term(), Path.t(), Path.t()) :: {:ok, argv()} | {:error, String.t()}
  def build_argv(template, input, output) do
    with {:ok, argv} <- parse_template(template) do
      args =
        Enum.map(argv, fn arg ->
          arg
          |> String.replace("{input}", input)
          |> String.replace("{output}", output)
        end)

      {:ok, @default_args ++ args}
    end
  end

  @doc """
  Runs ffmpeg with `argv`.

  Options:
    * `:timeout` — milliseconds (default: infinity)
    * `:on_line` — `fn line, acc -> acc end` called for every output line
    * `:acc` — initial accumulator for `:on_line`

  Returns `{:ok, acc}`, `{:error, {:exit_status, code}, acc}`,
  `{:error, :timeout, acc}` or `{:error, :not_found, acc}`.
  """
  @spec run(argv(), [run_option()]) :: run_result()
  def run(argv, opts \\ []) do
    case config()[:runner] do
      nil ->
        case executable() do
          nil -> {:error, :not_found, Keyword.get(opts, :acc)}
          path -> exec(path, argv, opts)
        end

      runner ->
        runner.run(argv, opts)
    end
  end

  @doc """
  Runs an arbitrary executable with the same options and results as `run/2`.
  A custom `:runner` module (with `run/2`) can be configured for tests.
  """
  @spec exec(Path.t(), argv(), [run_option()]) :: run_result()
  def exec(path, argv, opts \\ []) do
    on_line = Keyword.get(opts, :on_line, fn _line, acc -> acc end)
    acc = Keyword.get(opts, :acc)
    timeout = Keyword.get(opts, :timeout, :infinity)

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:line, 8192},
        args: argv
      ])

    os_pid = port |> Port.info(:os_pid) |> elem(1)
    guardian = start_guardian(self(), os_pid)
    deadline = if timeout == :infinity, do: :infinity, else: now() + timeout

    try do
      loop(port, os_pid, deadline, on_line, acc, "")
    after
      send(guardian, :done)
    end
  end

  @spec loop(
          port(),
          non_neg_integer(),
          integer() | :infinity,
          (String.t(), acc() -> acc()),
          acc(),
          String.t()
        ) :: run_result()
  defp loop(port, os_pid, deadline, on_line, acc, partial) do
    wait = if deadline == :infinity, do: :infinity, else: max(deadline - now(), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        loop(port, os_pid, deadline, on_line, acc, partial <> chunk)

      {^port, {:data, {:eol, chunk}}} ->
        line = String.trim_trailing(partial <> chunk, "\r")
        acc = if line == "", do: acc, else: on_line.(line, acc)
        loop(port, os_pid, deadline, on_line, acc, "")

      {^port, {:exit_status, 0}} ->
        {:ok, flush_partial(partial, on_line, acc)}

      {^port, {:exit_status, code}} ->
        {:error, {:exit_status, code}, flush_partial(partial, on_line, acc)}
    after
      wait ->
        kill(os_pid)
        safe_close(port)
        {:error, :timeout, flush_partial(partial, on_line, acc)}
    end
  end

  defp flush_partial("", _on_line, acc), do: acc
  defp flush_partial(partial, on_line, acc), do: on_line.(partial, acc)

  @spec start_guardian(pid(), non_neg_integer()) :: pid()
  defp start_guardian(owner, os_pid) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :done -> :ok
        {:DOWN, ^ref, :process, _, _} -> kill(os_pid)
      end
    end)
  end

  @doc false
  @spec kill(non_neg_integer()) :: :ok
  def kill(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/T", "/PID", to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp config, do: Application.get_env(:akvy, __MODULE__, [])

  @spec executable() :: String.t() | nil
  defp executable do
    path = config()[:path] || "ffmpeg"

    cond do
      Path.type(path) == :absolute and File.exists?(path) -> path
      true -> System.find_executable(path)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
