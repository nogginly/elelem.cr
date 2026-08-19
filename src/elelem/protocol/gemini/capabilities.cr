require "../../capability/profile"

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
  PROFILE = Capability::Profile.new(
    provider: NAME,
    accepted_media: {
      MPSH::BlockKind::Image    => Set{"image/png", "image/jpeg", "image/gif", "image/webp", "image/heic"},
      MPSH::BlockKind::Audio    => Set{"audio/wav", "audio/mpeg", "audio/ogg", "audio/flac"},
      MPSH::BlockKind::Document => Set{"application/pdf"},
    },
    binary_form: Capability::BinaryForm::Native,
    tool_calls: Capability::ToolCallForm::Block,
    tool_results: Capability::ToolResultForm::TextOnly,
    server_executed: true,
    refusal_channel: false,
    can_synthesize_user_message: true,
    system_placement: Capability::SystemPlacement::Structured,
    string_shorthand: false
  )
end
