defmodule Akvy.FFmpegTest do
  use ExUnit.Case, async: true

  alias Akvy.FFmpeg

  describe "parse_template/1" do
    test "accepts templates with both placeholders" do
      assert {:ok, ["-i", "{input}", "-vf", "scale=1280:-2", "{output}"]} =
               FFmpeg.parse_template("-i {input} -vf scale=1280:-2 {output}")
    end

    test "supports quoted arguments" do
      assert {:ok, ["-i", "{input}", "-metadata", "title=My clip", "{output}"]} =
               FFmpeg.parse_template(~s(-i {input} -metadata "title=My clip" {output}))
    end

    test "rejects invalid templates" do
      assert {:error, "must contain {input}"} = FFmpeg.parse_template("-y {output}")
      assert {:error, "must contain {output}"} = FFmpeg.parse_template("-i {input}")
      assert {:error, "must not be empty"} = FFmpeg.parse_template("  ")

      assert {:error, "must not include the ffmpeg binary"} =
               FFmpeg.parse_template("ffmpeg -i {input} {output}")
    end
  end

  test "build_argv/3 substitutes paths and prepends safe defaults" do
    assert {:ok, argv} = FFmpeg.build_argv("-i {input} {output}", "/w/in", "/w/out.mp4")
    assert argv == ["-nostdin", "-y", "-hide_banner", "-nostats", "-i", "/w/in", "/w/out.mp4"]
  end

  describe "exec/3" do
    setup do
      {:ok, erl: System.find_executable("erl")}
    end

    test "streams output lines and returns the exit status", %{erl: erl} do
      argv = ["-noshell", "-eval", ~s|io:format("one~ntwo~n"), halt(3).|]
      on_line = fn line, acc -> [line | acc] end

      assert {:error, {:exit_status, 3}, lines} =
               FFmpeg.exec(erl, argv, acc: [], on_line: on_line)

      assert Enum.reverse(lines) == ["one", "two"]
    end

    test "returns ok on exit status 0", %{erl: erl} do
      assert {:ok, nil} = FFmpeg.exec(erl, ["-noshell", "-eval", "halt(0)."])
    end

    test "kills the process on timeout", %{erl: erl} do
      argv = ["-noshell", "-eval", "timer:sleep(30000), halt(0)."]
      assert {:error, :timeout, nil} = FFmpeg.exec(erl, argv, timeout: 300)
    end
  end
end
