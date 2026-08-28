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

  # Where a reasoning item can live in a *request*, which is a different
  # question from whether a response returns one.
  enum ReasoningForm
    Block # a content block (Anthropic)
    Item  # an item in the input array (Responses)
    Field # a message-level field, e.g. `reasoning_content`
    None  # no home at all; replaying reasoning is impossible
  end

  # Which unit a *request* may use to ask for reasoning. A different question
  # from `ReasoningForm`, which asks where a reasoning item from a past turn can
  # be replayed. The two are independent: a profile targeting OpenAI's endpoint
  # strictly carries no past reasoning at all (`ReasoningForm::None`) while
  # accepting `reasoning_effort` on the same request.
  #
  # `Either` is not indecision. Two protocols genuinely accept both units and
  # reject being handed both at once, and which one a given deployment wants is
  # a fact about the *model*, not the protocol — Claude 4.7 rejects a budget,
  # Claude Sonnet 4.5 has no effort parameter, and Gemini splits at the 2.5/3
  # line. `Either` is the honest protocol-level declaration, narrowed per call
  # by `Catalog`.
  enum ReasoningUnit
    None   # no control at all; a request cannot ask
    Effort # a named rung
    Budget # a token count
    Either # both are spelled; the deployment decides which
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
    getter reasoning : ReasoningForm
    # What a request may ask of the model's reasoning. Distinct from
    # `reasoning` above, which governs replaying a past reasoning item.
    getter reasoning_unit : ReasoningUnit
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
    # Whether this protocol's native reasoning form is only valid carrying a
    # replayable payload the vendor itself issued — a `signature` or
    # equivalent opaque field — rather than text alone.
    #
    # Declared false everywhere except Anthropic, and declared from a live
    # 400 rather than documentation: a `thinking` block with no `signature`
    # is not merely unauthenticated, it fails Anthropic's own request schema
    # (`messages.N.content.M.thinking.signature: Field required`). Without
    # this flag, `Resolver#own?`'s "empty metadata is portable by
    # construction" rule — correct for a protocol with no signature concept
    # — called this block `Exact` and sent an invalid request. See
    # `spec/live/anthropic_spec.cr` and `SCOPE.md`'s "Known gap".
    getter? reasoning_signature_required : Bool

    # Whether this protocol's tool calls are only valid carrying a replayable
    # payload the vendor itself issued, the same way `thinking` blocks are on
    # Anthropic. Separate flag rather than a reuse of the one above, because
    # the two are genuinely independent: Gemini requires a signature on a
    # `functionCall` part and requires nothing of the sort on a plain-text
    # `thought` part, so one protocol needs to answer the two questions
    # differently.
    #
    # Declared from a live 400 rather than documentation (`Function call is
    # missing a thought_signature in functionCall parts`). Without it,
    # `Resolver#own?`'s "empty metadata is portable by construction" rule
    # calls a foreign tool call `Exact` and sends an invalid request —
    # precisely the shape this shard exists to produce, since a tool call
    # minted on another protocol never carries a Gemini signature.
    #
    # Defaults false on every protocol *including Gemini*, and is switched on
    # per model by `Catalog`, because the requirement arrived with Gemini 3
    # and the 2.5 series genuinely does not have it. Declaring it protocol-wide
    # was tried first and rejected: it would drop every tool call handed to a
    # 2.5 deployment, silently and permanently, to avoid a 400 that names the
    # missing field outright. See `Catalog::SIGNED_TOOL_CALLS`.
    getter? tool_call_signature_required : Bool

    def initialize(
      @provider : String,
      metadata_key : String? = nil,
      @accepted_media : Hash(MPSH::BlockKind, Set(String)) = {} of MPSH::BlockKind => Set(String),
      @binary_form : BinaryForm = BinaryForm::Native,
      @tool_calls : ToolCallForm = ToolCallForm::Block,
      @tool_results : ToolResultForm = ToolResultForm::Blocks,
      @reasoning : ReasoningForm = ReasoningForm::Block,
      @reasoning_unit : ReasoningUnit = ReasoningUnit::None,
      @server_executed : Bool = false,
      @refusal_channel : Bool = false,
      @can_synthesize_user_message : Bool = true,
      @alternation_required : Bool = false,
      @first_message_must_be_user : Bool = false,
      @system_placement : SystemPlacement = SystemPlacement::InMessages,
      @string_shorthand : Bool = true,
      @reasoning_signature_required : Bool = false,
      @tool_call_signature_required : Bool = false,
    )
      @metadata_key = metadata_key || @provider
    end

    def accepts?(kind : MPSH::BlockKind, media_type : String) : Bool
      (set = @accepted_media[kind]?) ? set.includes?(media_type) : false
    end

    # The same protocol, told that this deployment does not issue or honour the
    # vendor's opaque data.
    #
    # Narrowing only, and only along this axis. `Resolver#own?` compares a
    # block's `provider_metadata` against `metadata_key`, so reassigning the
    # key is enough to make a foreign signature stop counting as native — the
    # existing degradation path then reports it. Nothing else about the
    # protocol changes, because nothing else about it has.
    def with_metadata_key(metadata_key : String) : Profile
      Profile.new(
        @provider,
        metadata_key: metadata_key,
        accepted_media: @accepted_media,
        binary_form: @binary_form,
        tool_calls: @tool_calls,
        tool_results: @tool_results,
        reasoning: @reasoning,
        reasoning_unit: @reasoning_unit,
        server_executed: @server_executed,
        refusal_channel: @refusal_channel,
        can_synthesize_user_message: @can_synthesize_user_message,
        alternation_required: @alternation_required,
        first_message_must_be_user: @first_message_must_be_user,
        system_placement: @system_placement,
        string_shorthand: @string_shorthand,
        reasoning_signature_required: @reasoning_signature_required,
        tool_call_signature_required: @tool_call_signature_required)
    end

    # The same protocol, told which of its two reasoning units this deployment
    # wants.
    #
    # Narrowing only, along the same lines as `with_metadata_key` and for the
    # same reason: only `Either` may be resolved, and only into one of the two
    # units it already spelled. Widening `None` into a control the wire does not
    # have, or swapping a declared unit for the other one, would be a profile
    # claiming a capability the protocol lacks — the one direction this model
    # does not offer, because being wrongly optimistic here is a 400 rather than
    # a recorded loss.
    def with_reasoning_unit(unit : ReasoningUnit) : Profile
      return self if unit == @reasoning_unit

      unless @reasoning_unit.either? && (unit.effort? || unit.budget?)
        raise ArgumentError.new(
          "#{@provider}: cannot narrow reasoning unit #{@reasoning_unit} to #{unit}; " \
          "only Either may be narrowed, and only to Effort or Budget")
      end

      Profile.new(
        @provider,
        metadata_key: @metadata_key,
        accepted_media: @accepted_media,
        binary_form: @binary_form,
        tool_calls: @tool_calls,
        tool_results: @tool_results,
        reasoning: @reasoning,
        reasoning_unit: unit,
        server_executed: @server_executed,
        refusal_channel: @refusal_channel,
        can_synthesize_user_message: @can_synthesize_user_message,
        alternation_required: @alternation_required,
        first_message_must_be_user: @first_message_must_be_user,
        system_placement: @system_placement,
        string_shorthand: @string_shorthand,
        reasoning_signature_required: @reasoning_signature_required,
        tool_call_signature_required: @tool_call_signature_required)
    end

    # The same protocol, told that this deployment's model authenticates its
    # own tool calls.
    #
    # Narrowing only, like its two siblings above, though the direction reads
    # backwards at first glance: turning this *on* asks the protocol to accept
    # **less** than it declared, since a call that would otherwise have mapped
    # `Exact` now has a condition to meet. `false` is the permissive value
    # here, which is why only `false -> true` is allowed and the reverse
    # raises — a catalog entry may add the requirement, never waive one a
    # protocol declared for itself.
    def with_tool_call_signature_required(required : Bool) : Profile
      return self if required == @tool_call_signature_required

      unless required
        raise ArgumentError.new(
          "#{@provider}: cannot waive tool_call_signature_required; " \
          "the catalog may add the requirement, never remove it")
      end

      Profile.new(
        @provider,
        metadata_key: @metadata_key,
        accepted_media: @accepted_media,
        binary_form: @binary_form,
        tool_calls: @tool_calls,
        tool_results: @tool_results,
        reasoning: @reasoning,
        reasoning_unit: @reasoning_unit,
        server_executed: @server_executed,
        refusal_channel: @refusal_channel,
        can_synthesize_user_message: @can_synthesize_user_message,
        alternation_required: @alternation_required,
        first_message_must_be_user: @first_message_must_be_user,
        system_placement: @system_placement,
        string_shorthand: @string_shorthand,
        reasoning_signature_required: @reasoning_signature_required,
        tool_call_signature_required: true)
    end
  end
end
