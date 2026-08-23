require "../../capability/profile"

module Elelem::Protocol::Responses
  METADATA_KEY = "openai"
  NAME         = "openai.responses"

  # Differs from Chat Completions in surface, not in assumptions: the system
  # prompt moves to `instructions`, everything becomes an item in a flat
  # `input` array rather than a message with fields. Flexible roles, no
  # alternation rule, string shorthand permitted, model in the body — all
  # identical, which is why passing both proves less than it appears to.
  #
  # One capability genuinely diverges, and it is the only fixture in the suite
  # where two protocols in the same family disagree: reasoning is an **item**
  # here, not a text field, so it can carry an opaque payload. Redacted
  # reasoning survives a round trip here and degrades on Chat Completions.
  #
  # **On statefulness.** This protocol can hold history server-side, via
  # `previous_response_id` chaining or a Conversations object, and accept only
  # the new turn. We target the stateless mode deliberately: handles are
  # disposable optimizations over an authoritative local record, they are Phase
  # 5 work, and they save transfer rather than cost — OpenAI bills the full
  # reprocessed context as input tokens on every call in a chain regardless.
  # When handles arrive they live in a provider binding, never in the profile.
  PROFILE = Capability::Profile.new(
    provider: NAME,
    # Both OpenAI protocols share one metadata namespace: an encrypted
    # reasoning item issued over either is replayable over the other.
    metadata_key: METADATA_KEY,
    accepted_media: {
      MPSH::BlockKind::Image    => Set{"image/png", "image/jpeg", "image/gif", "image/webp"},
      MPSH::BlockKind::Audio    => Set{"audio/wav", "audio/mpeg"},
      MPSH::BlockKind::Document => Set{"application/pdf"},
    },
    binary_form: Capability::BinaryForm::DataUri,
    # `reasoning.effort`, the same ladder as Chat Completions in a nested
    # spelling. The family that agrees with itself about units, having
    # disagreed about everything else.
    reasoning_unit: Capability::ReasoningUnit::Effort,
    tool_calls: Capability::ToolCallForm::Field,
    tool_results: Capability::ToolResultForm::TextOnly,
    server_executed: true,
    refusal_channel: true,
    can_synthesize_user_message: true,
    system_placement: Capability::SystemPlacement::Instructions,
    string_shorthand: true
  )
end
