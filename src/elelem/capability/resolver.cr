require "./profile"
require "./policy"
require "../mpsh/block"

module Elelem::Capability
  # One algorithm, four declarations.
  #
  # The capability matrix in the specification is written as a table, but a
  # hand-written table per protocol is four places to forget the same rule. The
  # table is instead *derived* from each protocol's `Profile`, so the matrix a
  # caller queries and the outcome a mapper acts on are guaranteed to be the
  # same fact.
  module Resolver
    extend self

    # Where a block sits changes what it may become.
    enum Nesting
      TopLevel
      InsideToolResult
      # Between a tool call and its result, within an unclosed turn.
      MidToolCall
    end

    def outcome(block : MPSH::Block, profile : Profile,
                nesting : Nesting = Nesting::TopLevel) : MPSH::Outcome
      case block
      in MPSH::TextBlock
        MPSH::Outcome::Exact
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary_outcome(block, profile, nesting)
      in MPSH::ToolCallBlock
        tool_call_outcome(block, profile)
      in MPSH::ToolResultBlock
        tool_result_outcome(block, profile)
      in MPSH::ReasoningBlock
        reasoning_outcome(profile, nesting)
      in MPSH::RefusalBlock
        # Ruling: the session plays back as it happened. A past refusal is just
        # history, and carrying its text to a provider with no refusal channel
        # loses nothing. A refusal with no text has nothing to carry, and that
        # is the case worth being told about.
        return MPSH::Outcome::Exact if profile.refusal_channel?
        block.reason ? MPSH::Outcome::Restructured : MPSH::Outcome::Degraded
      end
    end

    # Foreign reasoning is not a loss: MPSH keeps the block, and the opaque
    # payload is shed by namespacing rather than by anyone deciding to shed it.
    # Calling it Degraded would make `strict` refuse every cross-provider
    # handoff of a reasoning-model session — precisely the move this shard
    # exists to perform.
    #
    # The exception is real. Some providers require a reasoning item be replayed
    # unmodified between a tool call and its result; dropping one there breaks
    # the turn rather than trimming it.
    private def reasoning_outcome(profile : Profile, nesting : Nesting) : MPSH::Outcome
      return MPSH::Outcome::Exact if profile.own_reasoning?
      nesting.mid_tool_call? ? MPSH::Outcome::Refused : MPSH::Outcome::Restructured
    end

    private def binary_outcome(block : MPSH::BinaryBlock, profile : Profile,
                               nesting : Nesting) : MPSH::Outcome
      carriable = profile.accepts?(block.kind, block.media_type) &&
                  !profile.binary_form.none?

      if carriable && nesting.inside_tool_result?
        # Anthropic takes it natively; the OpenAI protocols cannot put binary
        # inside a tool result at all, however well they take it elsewhere.
        return profile.tool_results.blocks? ? native_or_restructured(profile) : compensate_or_fall_back(block, profile)
      end

      return native_or_restructured(profile) if carriable
      block.text_fallback ? MPSH::Outcome::Degraded : MPSH::Outcome::Refused
    end

    private def native_or_restructured(profile : Profile) : MPSH::Outcome
      profile.binary_form.native? ? MPSH::Outcome::Exact : MPSH::Outcome::Restructured
    end

    private def compensate_or_fall_back(block : MPSH::BinaryBlock, profile : Profile) : MPSH::Outcome
      # The fixture that forced this whole model: a tool returning a screenshot.
      # Chat Completions can only render it as a placeholder result plus a
      # synthetic user message carrying the image.
      return MPSH::Outcome::Compensated if profile.can_synthesize_user_message? &&
                                           profile.accepts?(block.kind, block.media_type)
      block.text_fallback ? MPSH::Outcome::Degraded : MPSH::Outcome::Refused
    end

    private def tool_call_outcome(block : MPSH::ToolCallBlock, profile : Profile) : MPSH::Outcome
      return MPSH::Outcome::Refused if profile.tool_calls.none?

      if block.server_executed?
        # A provider-run call is never dispatched by a client, and almost never
        # has an equivalent elsewhere. Where it has none, the result survives as
        # conversation and the tool framing does not.
        return profile.server_executed? ? MPSH::Outcome::Exact : MPSH::Outcome::Degraded
      end

      profile.tool_calls.block? ? MPSH::Outcome::Exact : MPSH::Outcome::Restructured
    end

    private def tool_result_outcome(block : MPSH::ToolResultBlock, profile : Profile) : MPSH::Outcome
      return MPSH::Outcome::Refused if profile.tool_results.none?
      return MPSH::Outcome::Degraded if block.server_executed? && !profile.server_executed?

      worst = profile.tool_results.blocks? ? MPSH::Outcome::Exact : MPSH::Outcome::Restructured
      block.content.each do |nested|
        nested_outcome = outcome(nested, profile, Nesting::InsideToolResult)
        worst = nested_outcome if nested_outcome > worst
      end
      worst
    end

    # The queryable matrix: the same resolver, run over a representative block
    # set, so a caller can know in advance what will degrade.
    def matrix(profile : Profile, blocks : Array(MPSH::Block)) : Hash(String, MPSH::Outcome)
      blocks.each_with_object({} of String => MPSH::Outcome) do |block, acc|
        label = case block
                in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
                  "#{block.kind}(#{block.media_type})"
                in MPSH::ToolResultBlock
                  block.text_only? ? "ToolResult(text)" : "ToolResult(mixed)"
                in MPSH::TextBlock, MPSH::ToolCallBlock, MPSH::ReasoningBlock, MPSH::RefusalBlock
                  block.kind.to_s
                end
        acc[label] = outcome(block, profile)
      end
    end
  end
end
