if Code.ensure_loaded?(Plug.Upload) do
  defmodule FileWard.Plug do
    @moduledoc "Adapter for trusted Plug multipart upload structs."

    @doc false
    def build(%Plug.Upload{path: path, filename: filename, content_type: type})
        when is_binary(path) and (is_nil(filename) or is_binary(filename)) and
               (is_nil(type) or is_binary(type)) do
      {:ok, :upload,
       fn state, write ->
         FileWard.Source.stream(
           File.stream!(path, 65_536, []),
           [filename: filename, content_type: type],
           state,
           write
         )
       end}
    end

    def build(_), do: FileWard.Error.result(:body, :invalid_source)
  end
end
