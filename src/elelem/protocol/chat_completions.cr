require "../capability/profile"

module Elelem::Protocol::ChatCompletions
  METADATA_KEY = "openai"
  NAME         = "openai.chat_completions"

  # Declared capabilities. Confirmed against provider documentation at the time
  # of writing and expected to drift — capabilities change faster than protocol
  # shapes, so this is the first thing to re-check when something behaves oddly.
  #
  # The two decisive facts: binary content is fused into a `data:` URI, and a
  # tool result is a string. The latter is why this protocol cannot express an
  # image-returning tool and must compensate.
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
    server_executed: false,
    refusal_channel: true,
    can_synthesize_user_message: true,
    alternation_required: false,
    first_message_must_be_user: false,
    system_placement: Capability::SystemPlacement::InMessages,
    string_shorthand: true
  )
end
