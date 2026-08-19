require "../../src/elelem"

# The conformance fixture set from `docs/MPSH_SPECIFICATION.md` §9.
#
# One definition, used by every protocol's suite. A fixture that only one
# protocol exercises is not a fixture, it is a unit test — the whole point is
# that the same conversation meets four sets of capabilities and diverges only
# where the matrix predicts.
#
# Everything here is structural: no API key, no model, no network, no HTTP
# object constructed.
module Elelem::Fixtures
  extend self

  alias M = Elelem::MPSH

  PNG  = "image/png"
  WEBP = "image/webp"
  WAV  = "audio/wav"
  PDF  = "application/pdf"

  # A short, obviously fake base64 body. Fixtures assert on structure, never on
  # payload contents, so brevity costs nothing.
  BYTES = "aGVsbG8="

  def inline(media_type : String) : M::Payload
    M::InlinePayload.new(BYTES, media_type, 5_i64)
  end

  def reference(media_type : String) : M::Payload
    M::ReferencePayload.new("blob:sha256-deadbeef", media_type, 4_096_i64)
  end

  def blocks(*items : M::Block) : Array(M::Block)
    items.to_a.map(&.as(M::Block))
  end

  def user(*items : M::Block) : M::Message
    M::Message.new(M::Role::User, blocks(*items))
  end

  def assistant(*items : M::Block) : M::Message
    M::Message.new(M::Role::Assistant, blocks(*items))
  end

  # A typed splat requires at least one argument, and an empty message is a
  # real fixture rather than an accident, so it gets its own name.
  def empty_user : M::Message
    M::Message.new(M::Role::User)
  end

  def text(body : String) : M::Block
    M::TextBlock.new(body)
  end

  def session(*messages : M::Message, system : String? = nil) : M::Session
    M::Session.new(system, messages.to_a)
  end

  # -- Baseline ------------------------------------------------------------

  def single_user_turn : M::Session
    session(user(text("What is the capital of France?")))
  end

  def multi_turn_alternating : M::Session
    session(
      user(text("What is the capital of France?")),
      assistant(text("Paris.")),
      user(text("And Spain?")),
      assistant(text("Madrid."))
    )
  end

  def with_system_prompt : M::Session
    session(user(text("Hello")), system: "You are a helpful assistant")
  end

  def without_system_prompt : M::Session
    session(user(text("Hello")))
  end

  # -- Structural edges ----------------------------------------------------

  # Merging these for an alternation-requiring protocol is one-way: export
  # cannot know where the seam was. The matrix predicts Compensated.
  def consecutive_same_role : M::Session
    session(
      user(text("Hello")),
      user(text("Are you there?")),
      assistant(text("Yes."))
    )
  end

  def assistant_first : M::Session
    session(
      assistant(text("Shall we continue where we left off?")),
      user(text("Yes, please."))
    )
  end

  def single_text_block : M::Session
    session(user(text("Just one block")))
  end

  # Three protocols may collapse this to a string; one has no shorthand at all.
  def multiple_text_blocks : M::Session
    session(user(text("First thought."), text("Second thought.")))
  end

  def empty_message : M::Session
    session(empty_user, user(text("Sorry, that was blank.")))
  end

  # -- Content blocks ------------------------------------------------------

  def text_and_image : M::Session
    session(user(
      text("What's in this image?"),
      M::ImageBlock.new(inline(PNG), text_fallback: "a photograph of a cat")
    ))
  end

  # Supported kind, unsupported media type. Capability is per media type, so
  # this must not resolve the same way as `text_and_image`.
  def unsupported_media_type : M::Session
    session(user(
      text("And this one?"),
      M::ImageBlock.new(inline(WEBP), text_fallback: "a diagram")
    ))
  end

  def reference_payload : M::Session
    session(user(
      text("Summarize the attached report."),
      M::DocumentBlock.new(reference(PDF), "q3-report.pdf", text_fallback: "Q3 report")
    ))
  end

  def audio_with_transcript : M::Session
    session(user(
      text("What did I say?"),
      M::AudioBlock.new(inline(WAV), text_fallback: "I said the meeting is at four.")
    ))
  end

  # No fallback: the only honest outcome is a loud refusal.
  def audio_without_transcript : M::Session
    session(user(
      text("What did I say?"),
      M::AudioBlock.new(inline(WAV))
    ))
  end

  # -- Tools ---------------------------------------------------------------

  CALL_WEATHER = "mc_fixture_weather"
  CALL_SCREEN  = "mc_fixture_screenshot"
  CALL_SEARCH  = "mc_fixture_search"

  def tool_call_text_result : M::Session
    args = M::Object{"city" => "Kyoto".as(M::Value)}
    session(
      user(text("What's the weather in Kyoto?")),
      assistant(M::ToolCallBlock.new(CALL_WEATHER, "get_weather", args)),
      user(M::ToolResultBlock.new(CALL_WEATHER, blocks(text("18C, light rain")))),
      assistant(text("Mild and drizzly."))
    )
  end

  # The fixture that forced the capability model. Nested content is
  # `[text, image]`, which one protocol expresses natively and another can only
  # render as a placeholder plus a synthesized user message.
  def tool_call_image_result : M::Session
    session(
      user(text("Screenshot the homepage.")),
      assistant(M::ToolCallBlock.new(CALL_SCREEN, "screenshot", M::Object.new)),
      user(M::ToolResultBlock.new(CALL_SCREEN, blocks(
        text("Captured at 1280x720."),
        M::ImageBlock.new(inline(PNG), text_fallback: "screenshot of a homepage")
      ))),
      assistant(text("The header is misaligned."))
    )
  end

  def tool_result_error : M::Session
    session(
      user(text("Screenshot the homepage.")),
      assistant(M::ToolCallBlock.new(CALL_SCREEN, "screenshot", M::Object.new)),
      user(M::ToolResultBlock.new(CALL_SCREEN, blocks(text("timed out")),
        is_error: true, exception: "Net::TimeoutError"))
    )
  end

  # Arrives already complete. A client that dispatches this is broken.
  #
  # Attributed to the provider that ran it: a server-executed tool is exact only
  # for its own provider, so the metadata key is what makes this fixture
  # discriminating rather than merely present.
  def server_executed_tool : M::Session
    args = M::Object{"query" => "crystal lang shards".as(M::Value)}
    call = M::ToolCallBlock.new(CALL_SEARCH, "web_search", args, server_executed: true)
    call.put_meta("anthropic", "tool_name", "web_search")

    result = M::ToolResultBlock.new(CALL_SEARCH, blocks(text("three results")),
      server_executed: true)
    result.put_meta("anthropic", "result_type", "web_search_tool_result")

    session(
      user(text("Search for Crystal shards.")),
      assistant(call),
      user(result),
      assistant(text("Here's what I found."))
    )
  end

  # -- Reasoning -----------------------------------------------------------

  def reasoning_with_text : M::Session
    session(
      user(text("Is 91 prime?")),
      assistant(M::ReasoningBlock.new("91 = 7 x 13"), text("No, it factors as 7 x 13."))
    )
  end

  # Reasoning happened; the provider withheld it. Retained as a structural
  # fact rather than an omission.
  def reasoning_redacted : M::Session
    session(
      user(text("Is 91 prime?")),
      assistant(M::ReasoningBlock.new(redacted: true), text("No."))
    )
  end

  def reasoning_with_provider_payload : M::Session
    block = M::ReasoningBlock.new(redacted: true)
    block.put_meta("openai", "encrypted_content", "b3BhcXVl")
    block.put_meta("openai", "item_id", "rs_fixture_001")
    session(
      user(text("Is 91 prime?")),
      assistant(block, text("No."))
    )
  end

  # An open turn: the tool call has not been answered, so the reasoning block
  # sits mid-tool-call and retention must not trim it.
  #
  # Attributed, and that attribution is the whole point. An unattributed
  # reasoning block is portable and maps exactly anywhere; only an opaque one
  # its issuer requires replayed unmodified can make this position a refusal.
  def reasoning_mid_tool_call : M::Session
    reasoning = M::ReasoningBlock.new(redacted: true)
    reasoning.put_meta("openai", "encrypted_content", "b3BhcXVl")

    session(
      user(text("What's the weather in Kyoto?")),
      assistant(
        reasoning,
        M::ToolCallBlock.new(CALL_WEATHER, "get_weather", M::Object.new)
      )
    )
  end

  # Two completed turns and one open, for exercising retention modes.
  def reasoning_across_turns : M::Session
    session(
      user(text("Is 91 prime?")),
      assistant(M::ReasoningBlock.new("7 x 13"), text("No.")),
      user(text("And 97?")),
      assistant(M::ReasoningBlock.new("no factors below 10"), text("Yes.")),
      user(text("And 101?")),
      assistant(M::ReasoningBlock.new("still prime"), text("Yes."))
    )
  end

  # -- Provider metadata ---------------------------------------------------

  # Carries data for a provider other than the one being mapped to. Must be
  # ignored, not misread.
  def foreign_provider_metadata : M::Session
    block = M::TextBlock.new("Paris.")
    block.put_meta("anthropic", "cache_control", "ephemeral")
    message = M::Message.new(M::Role::Assistant, blocks(block))
    message.put_meta("anthropic", "stop_reason", "end_turn")
    session(user(text("Capital of France?")), message)
  end

  # -- Refusal -------------------------------------------------------------

  def refusal_with_reason : M::Session
    session(
      user(text("Who is in this photo?")),
      assistant(M::RefusalBlock.new("I don't identify people in images."))
    )
  end

  # Nothing to carry to a protocol with no refusal channel.
  def refusal_without_reason : M::Session
    session(
      user(text("Who is in this photo?")),
      assistant(M::RefusalBlock.new)
    )
  end

  # -- The whole set -------------------------------------------------------

  def all : Hash(String, M::Session)
    {
      "single_user_turn"                => single_user_turn,
      "multi_turn_alternating"          => multi_turn_alternating,
      "with_system_prompt"              => with_system_prompt,
      "without_system_prompt"           => without_system_prompt,
      "consecutive_same_role"           => consecutive_same_role,
      "assistant_first"                 => assistant_first,
      "single_text_block"               => single_text_block,
      "multiple_text_blocks"            => multiple_text_blocks,
      "empty_message"                   => empty_message,
      "text_and_image"                  => text_and_image,
      "unsupported_media_type"          => unsupported_media_type,
      "reference_payload"               => reference_payload,
      "audio_with_transcript"           => audio_with_transcript,
      "audio_without_transcript"        => audio_without_transcript,
      "tool_call_text_result"           => tool_call_text_result,
      "tool_call_image_result"          => tool_call_image_result,
      "tool_result_error"               => tool_result_error,
      "server_executed_tool"            => server_executed_tool,
      "reasoning_with_text"             => reasoning_with_text,
      "reasoning_redacted"              => reasoning_redacted,
      "reasoning_with_provider_payload" => reasoning_with_provider_payload,
      "reasoning_mid_tool_call"         => reasoning_mid_tool_call,
      "reasoning_across_turns"          => reasoning_across_turns,
      "foreign_provider_metadata"       => foreign_provider_metadata,
      "refusal_with_reason"             => refusal_with_reason,
      "refusal_without_reason"          => refusal_without_reason,
    }
  end
end
