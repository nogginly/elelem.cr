require "../capability/profile"

module Elelem::Protocol::Anthropic
  NAME = "anthropic"

  # The most capable target and the strictest validator at once.
  #
  # `tool_results: Blocks` is the capability that forced the union rule: a tool
  # returning a screenshot is natively expressible here, and an intersection
  # format would have deleted it to accommodate protocols that lack it.
  #
  # No audio. A voice note reaching this protocol degrades to its transcript, or
  # refuses if it has none.
  PROFILE = Capability::Profile.new(
    provider: NAME,
    accepted_media: {
      MPSH::BlockKind::Image    => Set{"image/png", "image/jpeg", "image/gif", "image/webp"},
      MPSH::BlockKind::Document => Set{"application/pdf"},
    },
    binary_form: Capability::BinaryForm::Native,
    tool_calls: Capability::ToolCallForm::Block,
    tool_results: Capability::ToolResultForm::Blocks,
    server_executed: true,
    refusal_channel: false,
    can_synthesize_user_message: true,
    alternation_required: true,
    first_message_must_be_user: true,
    system_placement: Capability::SystemPlacement::Parameter,
    string_shorthand: true
  )
end
