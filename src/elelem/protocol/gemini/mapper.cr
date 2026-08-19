require "./wire"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../capability/structural"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::Gemini
  COMPENSATION_PLACEHOLDER = "[elelem: content returned separately in the following message]"

  # MPSH view in, request body out.
  #
  # The mapping is mostly mechanical wrapping — roles renamed, everything into
  # `parts` — with one genuinely different problem: **there is nowhere to put a
  # tool call identifier.**
  #
  # MPSH mints `call_id` and the other three protocols carry it under some name.
  # Here the wire has no field for it and inventing one risks rejection, so the
  # pairing must be reconstructible from what the wire *does* carry: the
  # function name, and the order calls appear in. The mapper records that
  # correspondence in the translation table so export can rebuild it.
  #
  # This is the fixture the `CallIdTable` design exists for, and the first time
  # it has had to work without a provider id to lean on.
  class Mapper
    getter profile : Capability::Profile
    getter calls : MPSH::CallIdTable

    def initialize(@profile : Capability::Profile = PROFILE,
                   @calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def map(session : MPSH::Session, model : String,
            policy : Capability::Policy = Capability::Policy::Compensating,
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All) : {Wire::Request, Capability::Report}
      report = Capability::Report.new(NAME, policy)
      plan = Capability::Retention.plan(session.messages, retention)
      report.reasoning_dropped = plan.dropped

      if session.system_prompt
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::MoveSystemPrompt),
          "system prompt to systemInstruction")
      end

      contents = [] of Wire::Content
      pending = [] of Wire::Part
      # How many times each function name has been called so far. The ordinal
      # plus the name *is* the identifier on this protocol.
      ordinals = Hash(String, Int32).new(0)

      session.messages.each_with_index do |message, index|
        parts = parts_for(message, index, report, plan, pending, ordinals)
        next if parts.empty?

        # Anything that is not itself a tool response ends the run and the
        # carrier goes out first — including a model turn. Flushing only before
        # user messages puts the carrier *after* the model's reply, where the
        # results it belongs to are no longer in view and export cannot absorb
        # it.
        unless parts.any?(Wire::FunctionResponsePart)
          flush_compensation(contents, pending, report)
        end

        contents << Wire::Content.new(role_of(message), parts)
      end

      flush_compensation(contents, pending, report)
      {Wire::Request.new(model, contents, session.system_prompt), report}
    end

    # `model`, not `assistant`. The single most common source of a silently
    # wrong mapping on this protocol.
    private def role_of(message : MPSH::Message) : String
      message.role.user? ? "user" : "model"
    end

    private def flush_compensation(contents : Array(Wire::Content),
                                   pending : Array(Wire::Part),
                                   report : Capability::Report) : Nil
      return if pending.empty?

      report.record(
        Capability::Structural.outcome(Capability::Structural::Adaptation::DeferCompensationCarrier),
        "compensation carrier deferred past #{pending.size} tool result(s)")

      contents << Wire::Content.new("user", pending.dup, synthetic: true)
      pending.clear
    end

    private def parts_for(message : MPSH::Message, index : Int32,
                          report : Capability::Report,
                          plan : Capability::Retention::Plan,
                          pending : Array(Wire::Part),
                          ordinals : Hash(String, Int32)) : Array(Wire::Part)
      parts = [] of Wire::Part

      message.content.each do |block|
        case block
        in MPSH::ReasoningBlock
          next unless plan.retain?(index)
          rendered = thought(block, index, report)
          parts << rendered if rendered
        in MPSH::ToolCallBlock
          rendered = function_call(block, index, report, ordinals)
          parts << rendered if rendered
        in MPSH::ToolResultBlock
          rendered = function_response(block, index, report, pending)
          parts << rendered if rendered
        in MPSH::RefusalBlock
          outcome = Capability::Resolver.outcome(block, profile)
          report.record(outcome, "refusal carried as text", index, MPSH::BlockKind::Refusal)
          block.reason.try { |reason| parts << Wire::TextPart.new(reason) }
        in MPSH::TextBlock, MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
          rendered = render(block, index, report)
          parts << rendered if rendered
        end
      end

      parts
    end

    # Records `name#ordinal` against the MPSH id, which is the only pairing
    # information that survives to the wire.
    private def function_call(block : MPSH::ToolCallBlock, index : Int32,
                              report : Capability::Report,
                              ordinals : Hash(String, Int32)) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool call as a functionCall part", index, MPSH::BlockKind::ToolCall)
      return nil if outcome.lossy?

      ordinal = ordinals[block.name]
      ordinals[block.name] = ordinal + 1
      calls.bind(block.call_id, calls.positional_key(block.name, ordinal))

      Wire::FunctionCallPart.new(block.name, block.arguments.to_json)
    end

    # A response names the function it answers. The name is recovered from the
    # translation table, since MPSH's `call_id` says nothing about it.
    private def function_response(block : MPSH::ToolResultBlock, index : Int32,
                                  report : Capability::Report,
                                  pending : Array(Wire::Part)) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool result as a functionResponse part",
        index, MPSH::BlockKind::ToolResult)
      return nil if outcome.lossy?

      text = [] of String
      block.content.each do |nested|
        case nested
        when MPSH::TextBlock
          text << nested.text
        else
          part = render(nested, index, report, Capability::Resolver::Nesting::InsideToolResult)
          if part
            pending << part
            text << COMPENSATION_PLACEHOLDER
          end
        end
      end

      Wire::FunctionResponsePart.new(function_name(block), {output: text.join("\n")}.to_json)
    end

    private def function_name(block : MPSH::ToolResultBlock) : String
      key = calls.provider_id(block.call_id)
      key ? key.rpartition('#')[0] : "unknown_function"
    end

    private def thought(block : MPSH::ReasoningBlock, index : Int32,
                        report : Capability::Report) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "reasoning as a thought part", index, MPSH::BlockKind::Reasoning)
      return nil if outcome.lossy?

      meta = block.meta_for(profile.metadata_key)
      Wire::ThoughtPart.new(block.text,
        signature: meta.try(&.["thought_signature"]?).try(&.as?(String)))
    end

    private def render(block : MPSH::Block, index : Int32, report : Capability::Report,
                       nesting = Capability::Resolver::Nesting::TopLevel) : Wire::Part?
      case block
      in MPSH::TextBlock
        Wire::TextPart.new(block.text)
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary(block, index, report, nesting)
      in MPSH::ToolCallBlock, MPSH::ToolResultBlock, MPSH::ReasoningBlock, MPSH::RefusalBlock
        nil
      end
    end

    private def binary(block : MPSH::BinaryBlock, index : Int32,
                       report : Capability::Report,
                       nesting : Capability::Resolver::Nesting) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile, nesting)
      report.record(outcome, "#{block.kind.to_s.downcase} #{block.media_type}", index, block.kind)

      case outcome
      when MPSH::Outcome::Degraded
        block.text_fallback.try { |text| Wire::TextPart.new(text) }
      when MPSH::Outcome::Refused
        nil
      else
        payload = materialize(block.payload)
        Wire::InlineDataPart.new(payload.media_type, payload.base64)
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
