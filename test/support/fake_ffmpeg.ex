defmodule Akvy.FakeFFmpeg do
  @moduledoc """
  Test double for ffmpeg. The behaviour is chosen per test process with
  `Akvy.FakeFFmpeg.set_mode/1` (`:ok`, `:fail`, `:timeout`, `:no_output`).
  `:ok` copies the input file to the output path.
  """

  def set_mode(mode), do: Process.put(__MODULE__, mode)

  def run(argv, opts) do
    on_line = Keyword.get(opts, :on_line, fn _line, acc -> acc end)
    acc = Keyword.get(opts, :acc)
    input = argv |> Enum.drop_while(&(&1 != "-i")) |> Enum.at(1)
    output = List.last(argv)

    acc = on_line.("Input #0, fake, from '#{input}':", acc)

    case Process.get(__MODULE__, :ok) do
      :ok ->
        File.cp!(input, output)
        {:ok, on_line.("video:1kB audio:0kB muxing overhead: 0%", acc)}

      :fail ->
        {:error, {:exit_status, 1}, on_line.("Invalid data found when processing input", acc)}

      :timeout ->
        {:error, :timeout, acc}

      :no_output ->
        {:ok, acc}
    end
  end
end
