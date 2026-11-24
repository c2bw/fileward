defmodule FileWard.Signatures do
  @moduledoc false

  def detect(<<137, "PNG", 13, 10, 26, 10, _::binary>>), do: "image/png"
  def detect(<<255, 216, 255, _::binary>>), do: "image/jpeg"

  def detect(<<"GIF", version::binary-size(3), _::binary>>) when version in ["87a", "89a"],
    do: "image/gif"

  def detect(<<"%PDF-", _::binary>>), do: "application/pdf"

  def detect(<<"PK", marker::binary-size(2), _::binary>>)
      when marker in [<<3, 4>>, <<5, 6>>, <<7, 8>>], do: "application/zip"

  def detect(_), do: nil
end
