# Development seeds: an admin account and a sample queue.
#
#     mix run priv/repo/seeds.exs
#
# Credentials can be overridden with SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD.
alias Akvy.{Accounts, Queues}

email = System.get_env("SEED_ADMIN_EMAIL", "admin@akvy.local")
password = System.get_env("SEED_ADMIN_PASSWORD", "admin-password-123")

unless Accounts.get_user_by_email(email) do
  {:ok, _} = Accounts.create_admin(%{email: email, password: password})
  IO.puts("Created admin #{email}")
end

if Queues.list_queues() == [] do
  {:ok, _} =
    Queues.create_queue(%{
      name: "video-h264-720p",
      description: "H.264/AAC MP4, 720p",
      ffmpeg_args:
        "-i {input} -vf scale=-2:720 -c:v libx264 -preset veryfast -crf 23 -c:a aac -b:a 128k -movflags +faststart {output}",
      output_extension: "mp4",
      output_content_type: "video/mp4",
      max_file_size_bytes: 2 * 1024 * 1024 * 1024,
      allowed_content_types: ["video/*"],
      result_ttl_seconds: 24 * 3600,
      max_attempts: 3,
      timeout_seconds: 3600,
      log_retention_days: 14
    })

  {:ok, _} =
    Queues.create_queue(%{
      name: "audio-mp3",
      description: "Extract audio track as MP3",
      ffmpeg_args: "-i {input} -vn -c:a libmp3lame -q:a 2 {output}",
      output_extension: "mp3",
      output_content_type: "audio/mpeg",
      max_file_size_bytes: 512 * 1024 * 1024,
      result_ttl_seconds: 6 * 3600,
      max_attempts: 2,
      timeout_seconds: 900,
      log_retention_days: 7
    })

  IO.puts("Created sample queues")
end
