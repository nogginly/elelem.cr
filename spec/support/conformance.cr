require "../spec_helper"

# The conformance gate, expressed once and applied to every protocol.
#
# An MPSH session mapped into a protocol and exported back must reproduce the
# original exactly — *except* where the capability matrix declares the mapping
# Compensated or Degraded, in which case the divergence must match what the
# matrix predicts.
#
# That "except" is why comparison cannot be `should eq`. A plain equality check
# reports every compensated fixture as broken forever, which trains everyone to
# ignore the suite. So comparison yields a list of divergences, and each fixture
# declares which it expects.
module Conformance
  extend self

  # What changed, described precisely enough to tell a bug from a prediction.
  enum Change
    MessageCount
    Role
    BlockCount
    BlockKind
    Text
    Payload
    MediaType
    ToolCallName
    ToolArguments
    ServerExecuted
    ProviderMetadata
    Redacted
    SystemPrompt
  end

  struct Divergence
    getter change : Change
    getter path : String
    getter detail : String

    def initialize(@change : Change, @path : String, @detail : String)
    end

    def to_s(io : IO) : Nil
      io << change << " at " << path << ": " << detail
    end
  end

  # Compares two sessions structurally. Deliberately not an equality check:
  # every difference is named, so a fixture can declare which it tolerates.
  def compare(original : M::Session, exported : M::Session) : Array(Divergence)
    found = [] of Divergence

    if original.system_prompt != exported.system_prompt
      found << Divergence.new(Change::SystemPrompt, "session",
        "#{original.system_prompt.inspect} became #{exported.system_prompt.inspect}")
    end

    if original.messages.size != exported.messages.size
      found << Divergence.new(Change::MessageCount, "session",
        "#{original.messages.size} became #{exported.messages.size}")
    end

    original.messages.each_with_index do |message, index|
      other = exported.messages[index]?
      break unless other
      compare_message(message, other, "message[#{index}]", found)
    end

    found
  end

  private def compare_message(a : M::Message, b : M::Message, path : String,
                              found : Array(Divergence)) : Nil
    if a.role != b.role
      found << Divergence.new(Change::Role, path, "#{a.role} became #{b.role}")
    end

    if a.content.size != b.content.size
      found << Divergence.new(Change::BlockCount, path,
        "#{a.content.size} blocks became #{b.content.size}")
    end

    compare_metadata(a.provider_metadata, b.provider_metadata, path, found)

    a.content.each_with_index do |block, index|
      other = b.content[index]?
      break unless other
      compare_block(block, other, "#{path}.content[#{index}]", found)
    end
  end

  private def compare_block(a : M::Block, b : M::Block, path : String,
                            found : Array(Divergence)) : Nil
    unless a.class == b.class
      found << Divergence.new(Change::BlockKind, path, "#{a.kind} became #{b.kind}")
      return
    end

    compare_metadata(a.provider_metadata, b.provider_metadata, path, found)

    case a
    in M::TextBlock
      other = b.as(M::TextBlock)
      if a.text != other.text
        found << Divergence.new(Change::Text, path, "#{a.text.inspect} became #{other.text.inspect}")
      end
    in M::ImageBlock, M::AudioBlock, M::DocumentBlock
      compare_binary(a, b.as(M::BinaryBlock), path, found)
    in M::ToolCallBlock
      other = b.as(M::ToolCallBlock)
      if a.name != other.name
        found << Divergence.new(Change::ToolCallName, path, "#{a.name} became #{other.name}")
      end
      if a.arguments != other.arguments
        found << Divergence.new(Change::ToolArguments, path, "arguments differ")
      end
      if a.server_executed? != other.server_executed?
        found << Divergence.new(Change::ServerExecuted, path, "server_executed flag lost")
      end
    in M::ToolResultBlock
      other = b.as(M::ToolResultBlock)
      if a.content.size != other.content.size
        found << Divergence.new(Change::BlockCount, path,
          "#{a.content.size} nested blocks became #{other.content.size}")
      end
      if a.server_executed? != other.server_executed?
        found << Divergence.new(Change::ServerExecuted, path, "server_executed flag lost")
      end
      a.content.each_with_index do |nested, index|
        peer = other.content[index]?
        break unless peer
        compare_block(nested, peer, "#{path}.nested[#{index}]", found)
      end
    in M::ReasoningBlock
      other = b.as(M::ReasoningBlock)
      if a.text != other.text
        found << Divergence.new(Change::Text, path, "reasoning text differs")
      end
      if a.redacted? != other.redacted?
        found << Divergence.new(Change::Redacted, path, "redacted flag differs")
      end
    in M::RefusalBlock
      other = b.as(M::RefusalBlock)
      if a.reason != other.reason
        found << Divergence.new(Change::Text, path, "refusal reason differs")
      end
    end
  end

  private def compare_binary(a : M::BinaryBlock, b : M::BinaryBlock, path : String,
                             found : Array(Divergence)) : Nil
    if a.media_type != b.media_type
      found << Divergence.new(Change::MediaType, path, "#{a.media_type} became #{b.media_type}")
    end

    original = a.payload
    exported = b.payload
    if original.is_a?(M::InlinePayload) && exported.is_a?(M::InlinePayload)
      if original.base64 != exported.base64
        found << Divergence.new(Change::Payload, path, "base64 differs")
      end
    elsif original.inline? != exported.inline?
      found << Divergence.new(Change::Payload, path,
        "#{original.inline? ? "inline" : "reference"} became #{exported.inline? ? "inline" : "reference"}")
    end
  end

  # Provider metadata that the wire had nowhere to carry is a real divergence
  # and must be named, not waved through — it is exactly the silent-drop failure
  # this design exists to prevent.
  private def compare_metadata(a : M::Metadata, b : M::Metadata, path : String,
                               found : Array(Divergence)) : Nil
    (a.keys - b.keys).each do |vendor|
      found << Divergence.new(Change::ProviderMetadata, path, "#{vendor} metadata dropped")
    end
  end
end
