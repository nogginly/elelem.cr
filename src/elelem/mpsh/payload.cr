module Elelem::MPSH
  # Binary content, in one of two forms. Both always carry `media_type` and
  # `byte_size` — the parts stay separate, and a `data:` URI is synthesized at
  # map time for the two protocols that want one. Concatenation is trivial;
  # parsing a URI back out is not.
  abstract class Payload
    getter media_type : String
    getter byte_size : Int64

    def initialize(@media_type : String, @byte_size : Int64)
    end

    abstract def inline? : Bool
  end

  # Base64 text, no `data:` prefix, ever.
  class InlinePayload < Payload
    getter base64 : String

    def initialize(@base64 : String, media_type : String, byte_size : Int64)
      super(media_type, byte_size)
    end

    def inline? : Bool
      true
    end
  end

  # A content-addressed handle into a blob store the caller owns.
  # Materialized at map time, never in storage.
  class ReferencePayload < Payload
    getter handle : String

    def initialize(@handle : String, media_type : String, byte_size : Int64)
      super(media_type, byte_size)
    end

    def inline? : Bool
      false
    end
  end
end
