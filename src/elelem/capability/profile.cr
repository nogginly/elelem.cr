require "../mpsh/block"

module Elelem::Capability
  # How a protocol carries a binary block that it does support.
  enum BinaryForm
    Native  # separate media type + base64 -> Exact
    DataUri # fused into a `data:` URI -> Restructured
    None    # not carried at all
  end

  enum ToolResultForm
    Blocks   # nested content list, images welcome (Anthropic)
    TextOnly # string output only (both OpenAI protocols)
    None
  end

  enum ToolCallForm
    Block # native content block (Anthropic, Gemini)
    Field # hoisted onto the message or emitted as an item (OpenAI)
    None
  end

  enum SystemPlacement
    InMessages   # Chat Completions `role: system` / `developer`
    Instructions # Responses API
    Parameter    # Anthropic `system`
    Structured   # Gemini `systemInstruction.parts`
  end

  # A protocol's declaration of what it can express. Values are a starting
  # point, never a source of truth: capabilities drift faster than protocol
  # shapes do, so each implementation confirms its own against live docs.
  #
  # Capability is declared **per media type**, not per block kind. "Supports
  # images" is too coarse for a model that takes PNG but not WEBP.
  struct Profile
    # Identifies the *protocol*, e.g. `openai.chat_completions`. Many providers
    # may speak one protocol — Ollama, LM Studio and vLLM all serve Chat
    # Completions — so this names the wire shape, never an endpoint.
    getter provider : String

    # Identifies whoever issues opaque data that must be echoed back, e.g.
    # `openai`. Distinct from `provider` on purpose: an encrypted reasoning item
    # is replayable over either OpenAI protocol, because the vendor that can
    # read it is the same either way. Defaults to `provider` where the two
    # coincide.
    getter metadata_key : String
    getter accepted_media : Hash(MPSH::BlockKind, Set(String))
    getter binary_form : BinaryForm
    getter tool_calls : ToolCallForm
    getter tool_results : ToolResultForm
    # Whether the protocol has a notion of provider-run tools at all. Whether a
    # *given* call is one of this provider's own is a property of the block, not
    # of the profile — see `Resolver#own?`.
    getter? server_executed : Bool
    getter? refusal_channel : Bool
    getter? can_synthesize_user_message : Bool
    getter? alternation_required : Bool
    getter? first_message_must_be_user : Bool
    getter system_placement : SystemPlacement
    getter? string_shorthand : Bool

    def initialize(
      @provider : String,
      metadata_key : String? = nil,
      @accepted_media : Hash(MPSH::BlockKind, Set(String)) = {} of MPSH::BlockKind => Set(String),
      @binary_form : BinaryForm = BinaryForm::Native,
      @tool_calls : ToolCallForm = ToolCallForm::Block,
      @tool_results : ToolResultForm = ToolResultForm::Blocks,
      @server_executed : Bool = false,
      @refusal_channel : Bool = false,
      @can_synthesize_user_message : Bool = true,
      @alternation_required : Bool = false,
      @first_message_must_be_user : Bool = false,
      @system_placement : SystemPlacement = SystemPlacement::InMessages,
      @string_shorthand : Bool = true,
    )
      @metadata_key = metadata_key || @provider
    end

    def accepts?(kind : MPSH::BlockKind, media_type : String) : Bool
      (set = @accepted_media[kind]?) ? set.includes?(media_type) : false
    end
  end
end
