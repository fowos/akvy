defmodule Akvy.Mailer do
  @moduledoc "Swoosh mailer for outgoing application email."
  use Swoosh.Mailer, otp_app: :akvy
end
