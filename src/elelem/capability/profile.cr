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
    getter provider : String
    getter accepted_media : Hash(MPSH::BlockKind, Set(String))
    getter binary_form : BinaryForm
    getter tool_calls : ToolCallForm
    getter tool_results : ToolResultForm
    getter? server_executed : Bool
    getter? own_reasoning : Bool
    getter? refusal_channel : Bool
    getter? can_synthesize_user_message : Bool
    getter? alternation_required : Bool
    getter? first_message_must_be_user : Bool
    getter system_placement : SystemPlacement
    getter? string_shorthand : Bool

    def initialize(
      @provider : String,
      @accepted_media : Hash(MPSH::BlockKind, Set(String)) = {} of MPSH::BlockKind => Set(String),
      @binary_form : BinaryForm = BinaryForm::Native,
      @tool_calls : ToolCallForm = ToolCallForm::Block,
      @tool_results : ToolResultForm = ToolResultForm::Blocks,
      @server_executed : Bool = false,
      @own_reasoning : Bool = false,
      @refusal_channel : Bool = false,
      @can_synthesize_user_message : Bool = true,
      @alternation_required : Bool = false,
      @first_message_must_be_user : Bool = false,
      @system_placement : SystemPlacement = SystemPlacement::InMessages,
      @string_shorthand : Bool = true,
    )
    end

    def accepts?(kind : MPSH::BlockKind, media_type : String) : Bool
      (set = @accepted_media[kind]?) ? set.includes?(media_type) : false
    end
  end
end
