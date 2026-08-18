require "./meta"
require "./payload"

module Elelem::MPSH
  # Discriminator. Exists for codecs and for capability lookup keyed by kind;
  # mappers should branch on the union with `case ... in`, not on this.
  enum BlockKind
    Text
    Image
    Audio
    Document
    ToolCall
    ToolResult
    Reasoning
    Refusal
  end

  # The layering mechanism, chosen once and applied everywhere: **module with
  # `abstract def`**. Crystal has no interfaces; a module that declares abstract
  # methods is the only construct that both shares implementation and is checked
  # at include time. No block has a common superclass, which is what allows
  # `Block` below to be a union and therefore exhaustively matchable.
  module BlockRole
    include ProviderScoped

    abstract def kind : BlockKind
  end

  # Blocks carrying binary payloads. `text_fallback` is the entire difference
  # between *degrade* and *refuse* — the field exists on every one of them;
  # whether it is populated decides the outcome.
  module BinaryBlock
    include BlockRole

    abstract def payload : Payload
    abstract def text_fallback : String?

    def media_type : String
      payload.media_type
    end
  end

  class TextBlock
    include BlockRole
    getter text : String

    def initialize(@text : String)
    end

    def kind : BlockKind
      BlockKind::Text
    end
  end

  class ImageBlock
    include BinaryBlock
    getter payload : Payload
    getter text_fallback : String?
    getter name : String?

    def initialize(@payload : Payload, @text_fallback : String? = nil, @name : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Image
    end
  end

  class AudioBlock
    include BinaryBlock
    getter payload : Payload
    # Typically a transcript.
    getter text_fallback : String?
    getter name : String?

    def initialize(@payload : Payload, @text_fallback : String? = nil, @name : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Audio
    end
  end

  class DocumentBlock
    include BinaryBlock
    getter payload : Payload
    getter name : String
    getter text_fallback : String?

    def initialize(@payload : Payload, @name : String, @text_fallback : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Document
    end
  end

  # Assistant-side. `call_id` is minted by MPSH; provider ids live in
  # translation state (see `translation.cr`), never here.
  #
  # `arguments` is stored structured, not as a JSON string, for the same reason
  # base64 is stored unfused: object-to-string is serialization, string-to-object
  # is parsing, and parsing is the direction that fails.
  class ToolCallBlock
    include BlockRole
    getter call_id : String
    getter name : String
    getter arguments : Object
    getter? server_executed : Bool

    def initialize(@call_id : String, @name : String, @arguments : Object = Object.new,
                   @server_executed : Bool = false)
    end

    def kind : BlockKind
      BlockKind::ToolCall
    end
  end

  # User-side. `content` is a nested block list — the single decision that makes
  # an image-returning tool representable at all, including for the providers
  # that support it natively.
  #
  # `is_error` says the tool reported failure. `exception` says the dispatch
  # itself blew up. They are different facts and conflating them loses one.
  class ToolResultBlock
    include BlockRole
    getter call_id : String
    getter content : Array(Block)
    getter? is_error : Bool
    getter exception : String?
    getter? server_executed : Bool

    def initialize(@call_id : String, @content : Array(Block) = [] of Block,
                   @is_error : Bool = false, @exception : String? = nil,
                   @server_executed : Bool = false)
    end

    def kind : BlockKind
      BlockKind::ToolResult
    end

    # Cheap predicate the capability resolver leans on.
    def text_only? : Bool
      content.all?(TextBlock)
    end
  end

  # `redacted: true` with empty text records that reasoning happened and the
  # provider withheld it. That is a fact about the conversation's structure and
  # is retained on handoff; the opaque payload rides in `provider_metadata` and
  # is shed automatically.
  class ReasoningBlock
    include BlockRole
    getter text : String?
    getter? redacted : Bool

    def initialize(@text : String? = nil, @redacted : Bool = false)
    end

    def kind : BlockKind
      BlockKind::Reasoning
    end
  end

  # Some protocols emit refusal on a channel distinct from text.
  class RefusalBlock
    include BlockRole
    getter reason : String?

    def initialize(@reason : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Refusal
    end
  end

  # The closed union. Being a union rather than an abstract base class is what
  # gives mappers `case block; in TextBlock ...` with compiler-enforced
  # exhaustiveness — the antidote to the stringly-typed neutral event that
  # every consumer had to re-parse.
  alias Block = TextBlock | ImageBlock | AudioBlock | DocumentBlock |
                ToolCallBlock | ToolResultBlock | ReasoningBlock | RefusalBlock
end
