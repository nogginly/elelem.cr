require "../../capability/profile"
require "../../reasoning"

module Elelem::Protocol::Gemini
  METADATA_KEY = "gemini"
  NAME         = "gemini"

  # The most structurally divergent protocol: assistant role renamed, every
  # message wrapped in `parts`, model in the URL path, and tool calls paired to
  # results by name and ordering with no identifier at all.
  #
  # Widest native media support of the four, and the only one taking audio
  # natively.
  #
  # `tool_results: TextOnly` is a conservative declaration pending confirmation
  # that `functionResponse` can carry inline binary data. If it can, this
  # becomes `Blocks` and the image-bearing tool result stops compensating here.
  # A named rung rendered as a token budget, for the 2.5-series deployments
  # that take one. Google's documented ranges differ per model — Flash tops out
  # lower than Pro — so these sit inside the narrowest of them rather than at
  # any one model's ceiling.
  #
  # `Max` is -1, which this protocol reads as *dynamic thinking*: the model
  # decides how much to spend. That is a better rendering of "no constraint"
  # than any large number would be, and it is the protocol's own idiom.
  REASONING_BUDGETS = {
    Reasoning::Effort::Low    => 1024,
    Reasoning::Effort::Medium => 4096,
    Reasoning::Effort::High   => 16_384,
    Reasoning::Effort::XHigh  => 24_576,
    Reasoning::Effort::Max    => -1,
  }

  # Three rungs, shouted. `xhigh` and `max` have no spelling here, so they
  # clamp to `HIGH` and the mapper records the loss — the same treatment a
  # media type outside the accepted set gets, one axis over.
  REASONING_LEVELS = {
    Reasoning::Effort::Low    => "LOW",
    Reasoning::Effort::Medium => "MEDIUM",
    Reasoning::Effort::High   => "HIGH",
    Reasoning::Effort::XHigh  => "HIGH",
    Reasoning::Effort::Max    => "HIGH",
  }

  PROFILE = Capability::Profile.new(
    provider: NAME,
    accepted_media: {
      MPSH::BlockKind::Image    => Set{"image/png", "image/jpeg", "image/gif", "image/webp", "image/heic"},
      MPSH::BlockKind::Audio    => Set{"audio/wav", "audio/mpeg", "audio/ogg", "audio/flac"},
      MPSH::BlockKind::Document => Set{"application/pdf"},
    },
    binary_form: Capability::BinaryForm::Native,
    # Both, split at the 2.5/3 line: `thinkingBudget` on the former,
    # `thinkingLevel` on the latter. Sending both in one `thinkingConfig` is a
    # 400, which is the sharpest argument for resolving the unit before a
    # mapper renders anything.
    reasoning_unit: Capability::ReasoningUnit::Either,
    tool_calls: Capability::ToolCallForm::Block,
    tool_results: Capability::ToolResultForm::TextOnly,
    server_executed: true,
    refusal_channel: false,
    can_synthesize_user_message: true,
    system_placement: Capability::SystemPlacement::Structured,
    string_shorthand: false
  )
end
