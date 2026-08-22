require "./wire/request"
require "../../options"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../capability/structural"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::Anthropic
  # Placeholder text for a message invented to satisfy the first-user rule.
  # A protocol marker on the same terms as the compensation placeholder: export
  # recognises scaffolding by it, so it must stay byte-identical.
  FIRST_USER_PLACEHOLDER = "[elelem: continuing a conversation that began earlier]"

  # MPSH view in, request body out.
  #
  # Two things distinguish this mapper from the OpenAI pair, and they pull in
  # opposite directions.
  #
  # It is the **most capable** target: tool results take nested blocks, so the
  # fixture that Chat Completions must fake maps here with no compensation at
  # all. That pair — one protocol faking a capability, one with it natively,
  # exercised by the same fixture — is what actually validates the design.
  #
  # It is also the **strictest validator**: roles must alternate, the first
  # message must be from the user, and `max_tokens` is required. None of those
  # is a block-level concern, so all three are handled by a normalisation pass
  # over the message sequence before any block is rendered.
  class Mapper
    getter profile : Capability::Profile
    getter calls : MPSH::CallIdTable

    def initialize(@profile : Capability::Profile = PROFILE,
                   @calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def map(session : MPSH::Session, model : String,
            policy : Capability::Policy = Capability::Policy::Compensating,
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All,
            max_tokens : Int32 = DEFAULT_MAX_TOKENS,
            options : Options = Options.new) : {Wire::Request, Capability::Report}
      report = Capability::Report.new(NAME, policy)
      plan = Capability::Retention.plan(session.messages, retention)
      report.reasoning_dropped = plan.dropped

      if session.system_prompt
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::MoveSystemPrompt), "system prompt to the system parameter")
      end

      rendered = session.messages.map_with_index do |message, index|
        Wire::Message.new(role_of(message), blocks_for(message, index, report, plan))
      end

      messages = normalize(rendered, report)
      # `options.max_output_tokens` wins when set. The positional `max_tokens`
      # stays because this protocol requires a value and had one before options
      # existed; it is the fallback, not a second way to say the same thing.
      {Wire::Request.new(model, messages, options.max_output_tokens || max_tokens,
        session.system_prompt, declarations(options)), report}
    end

    # Tool declarations and generation options, translated per protocol.
    #
    # Added as a trailing parameter rather than folded in with `policy` and
    # `retention`: those govern what may be lost translating *history*, these
    # govern what the model is asked to do *next*. Two questions that happen to
    # ride on one call.
    private def declarations(options : Options) : Array(Wire::ToolDeclaration)
      options.tools.map do |tool|
        Wire::ToolDeclaration.new(tool.name, tool.description, tool.parameters)
      end
    end

    private def role_of(message : MPSH::Message) : String
      message.role.user? ? "user" : "assistant"
    end

    # Sequence-level normalisation, applied after rendering and before sending.
    #
    # Both adaptations are Compensated rather than Restructured, and for the
    # same reason: they are one-way. Export sees the merged message, or the
    # placeholder, with no way to recover what was there before — so the
    # conformance suite asserts the *predicted* divergence rather than fidelity.
    private def normalize(messages : Array(Wire::Message),
                          report : Capability::Report) : Array(Wire::Message)
      # Dropping an empty message is Degraded, so it is recorded rather than
      # done quietly. A silent drop is exactly the failure this design exists to
      # prevent, and it is easy to reach for `reject` without noticing.
      messages.count(&.content.empty?).times do
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::DropEmptyMessage),
          "empty message removed to satisfy validation")
      end

      messages = messages.reject(&.content.empty?)
      return messages if messages.empty?

      if messages.first.role == "assistant"
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::PrependUserPlaceholder),
          "history opens with an assistant turn")
        messages.unshift(Wire::Message.new("user",
          [Wire::TextBlock.new(FIRST_USER_PLACEHOLDER).as(Wire::Block)], synthetic: true))
      end

      merged = [] of Wire::Message
      messages.each do |message|
        previous = merged.last?
        if previous && previous.role == message.role
          report.record(Capability::Structural.outcome(
            Capability::Structural::Adaptation::MergeConsecutiveRoles),
            "consecutive #{message.role} messages merged")
          merged[merged.size - 1] = Wire::Message.new(
            previous.role, previous.content + message.content, previous.synthetic?)
        else
          merged << message
        end
      end

      merged
    end

    private def blocks_for(message : MPSH::Message, index : Int32,
                           report : Capability::Report,
                           plan : Capability::Retention::Plan) : Array(Wire::Block)
      blocks = [] of Wire::Block

      message.content.each do |block|
        case block
        in MPSH::ReasoningBlock
          next unless plan.retain?(index)
          rendered = thinking(block, index, report)
          blocks << rendered if rendered
        in MPSH::ToolCallBlock
          rendered = tool_use(block, index, report)
          blocks << rendered if rendered
        in MPSH::ToolResultBlock
          rendered = tool_result(block, index, report)
          blocks << rendered if rendered
        in MPSH::RefusalBlock
          rendered = refusal(block, index, report)
          blocks << rendered if rendered
        in MPSH::TextBlock, MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
          rendered = render(block, index, report)
          blocks << rendered if rendered
        end
      end

      blocks
    end

    # The exact path, and the counterpart to Chat Completions' compensation.
    # Nested content maps straight through — a screenshot stays a screenshot,
    # in position, with no placeholder and no synthesized message.
    private def tool_result(block : MPSH::ToolResultBlock, index : Int32,
                            report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool result with nested content",
        index, MPSH::BlockKind::ToolResult)
      return nil if outcome.lossy?

      nested = [] of Wire::Block
      block.content.each do |inner|
        rendered = render(inner, index, report, Capability::Resolver::Nesting::InsideToolResult)
        nested << rendered if rendered
      end

      provider_id = calls.provider_id(block.call_id) || block.call_id

      if block.server_executed?
        meta = block.meta_for(profile.metadata_key)
        block_type = meta.try(&.["result_type"]?).try(&.as?(String)) || "web_search_tool_result"
        return Wire::ServerToolResultBlock.new(provider_id, nested, block_type)
      end

      Wire::ToolResultBlock.new(provider_id, nested, block.is_error?)
    end

    private def tool_use(block : MPSH::ToolCallBlock, index : Int32,
                         report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool call as a tool_use block", index, MPSH::BlockKind::ToolCall)
      return nil if outcome.lossy?

      provider_id = calls.provider_id(block.call_id) || block.call_id
      calls.bind(block.call_id, provider_id)

      # A provider-run tool is its own block type here. Emitting one as an
      # ordinary `tool_use` would lose the flag and invite a client to dispatch
      # a tool it does not have — a correctness bug, not a fidelity one.
      if block.server_executed?
        return Wire::ServerToolUseBlock.new(provider_id, block.name, block.arguments.to_json)
      end

      Wire::ToolUseBlock.new(provider_id, block.name, block.arguments.to_json)
    end

    private def thinking(block : MPSH::ReasoningBlock, index : Int32,
                         report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "reasoning as a thinking block", index, MPSH::BlockKind::Reasoning)
      return nil if outcome.lossy?

      meta = block.meta_for(profile.metadata_key)
      Wire::ThinkingBlock.new(block.text,
        signature: meta.try(&.["signature"]?).try(&.as?(String)),
        redacted_data: meta.try(&.["redacted_data"]?).try(&.as?(String)))
    end

    # No refusal channel here, so the reason is carried as text. A refusal with
    # no reason has nothing to carry, which the resolver reports as Degraded.
    private def refusal(block : MPSH::RefusalBlock, index : Int32,
                        report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "refusal carried as text", index, MPSH::BlockKind::Refusal)
      block.reason.try { |reason| Wire::TextBlock.new(reason) }
    end

    private def render(block : MPSH::Block, index : Int32, report : Capability::Report,
                       nesting = Capability::Resolver::Nesting::TopLevel) : Wire::Block?
      case block
      in MPSH::TextBlock
        Wire::TextBlock.new(block.text)
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary(block, index, report, nesting)
      in MPSH::ToolCallBlock, MPSH::ToolResultBlock, MPSH::ReasoningBlock, MPSH::RefusalBlock
        nil
      end
    end

    # The first protocol where the degrade-versus-refuse ladder actually fires:
    # no audio media type is accepted, so a voice note becomes its transcript or
    # stops the request.
    private def binary(block : MPSH::BinaryBlock, index : Int32,
                       report : Capability::Report,
                       nesting : Capability::Resolver::Nesting) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile, nesting)
      report.record(outcome, "#{block.kind.to_s.downcase} #{block.media_type}", index, block.kind)

      case outcome
      when MPSH::Outcome::Degraded
        block.text_fallback.try { |text| Wire::TextBlock.new(text) }
      when MPSH::Outcome::Refused
        nil
      else
        payload = materialize(block.payload)
        case block
        when MPSH::ImageBlock
          Wire::ImageBlock.new(payload.media_type, payload.base64)
        when MPSH::DocumentBlock
          Wire::DocumentBlock.new(payload.media_type, payload.base64, block.name)
        end
      end
    end

    private def materialize(payload : MPSH::Payload) : MPSH::InlinePayload
      case payload
      when MPSH::InlinePayload then payload
      else
        raise Capability::RefusedError.new(NAME,
          "reference payload #{payload.media_type} cannot be materialized: no blob store configured")
      end
    end
  end
end
