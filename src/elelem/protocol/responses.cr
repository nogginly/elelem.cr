require "../capability/profile"

module Elelem::Protocol::Responses
  METADATA_KEY = "openai"
  NAME         = "openai.responses"

  # Differs from Chat Completions in surface, not in assumptions: the system
  # prompt moves to `instructions`, tool calls become items rather than a
  # message field. Every capability that matters is identical, which is why
  # passing both proves less than it appears to.
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
    tool_calls: Capability::ToolCallForm::Field,
    tool_results: Capability::ToolResultForm::TextOnly,
    server_executed: true,
    refusal_channel: true,
    can_synthesize_user_message: true,
    system_placement: Capability::SystemPlacement::Instructions,
    string_shorthand: true
  )
end
