require "./wire/request"
require "../../options"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../capability/reasoning_control"
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
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All,
            options : Options = Options.new) : {Wire::Request, Capability::Report}
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
      budget, level = reasoning(options, model, report)

      {Wire::Request.new(model, contents, session.system_prompt, declarations(options),
        options.max_output_tokens, thinking_budget: budget, thinking_level: level), report}
    end

    # At most one of the two is ever returned. Setting both in one
    # `thinkingConfig` is a 400 here, not a precedence rule, so the deployment's
    # unit is resolved before this runs and the other stays `nil`.
    #
    # No clamp against the output cap, unlike Anthropic: this protocol
    # documents no relationship between a thinking budget and
    # `maxOutputTokens`, and inventing one would be a rule of ours dressed up as
    # a rule of theirs. Worth revisiting the first time a live call disagrees.
    private def reasoning(options : Options, model : String,
                          report : Capability::Report) : {Int32?, String?}
      request = options.reasoning
      return {nil, nil} unless request

      unit = profile.reasoning_unit
      rendering, outcome = Capability::ReasoningControl.resolve(request, unit)

      # Confirmed live by a 400, not documentation: `thinkingBudget: 0` — this
      # rendering's compatibility fallback for a levels-preferring model — is
      # `Budget 0 is invalid. This model only works in thinking mode.` on some
      # models, not a silent accept. A tier-specific fact
      # (`CANNOT_DISABLE_THINKING`, `capabilities.cr`), not a generation-wide
      # one — Flash honours a budget of 0 correctly
      # (`spec/live/gemini_spec.cr`). The lowest rung this protocol spells is
      # the closest honest substitute, and it is a real loss: the caller
      # asked for no thinking and gets some regardless, so it is `Degraded`
      # and recorded rather than sent as the silent `Exact` `resolve()`
      # would otherwise claim for this rendering.
      if rendering.disable? && CANNOT_DISABLE_THINKING.includes?(model)
        report.record(MPSH::Outcome::Degraded,
          "reasoning control: reasoning off not supported on #{model}, sent as the lowest rung instead")
        return {nil, REASONING_LEVELS[Reasoning::Effort::Low]}
      end

      report.record(outcome, Capability::ReasoningControl.detail(request, rendering, unit))

      case rendering
      in Capability::ReasoningControl::Rendering::AsEffort
        {nil, level_for(request, report)}
      in Capability::ReasoningControl::Rendering::AsBudget
        budget = case request
                 in Reasoning::Effort then REASONING_BUDGETS[request]
                 in Reasoning::Budget then request.tokens
                 in Reasoning::Off    then 0
                 end
        {budget, nil}
      in Capability::ReasoningControl::Rendering::Disable
        {0, nil}
      in Capability::ReasoningControl::Rendering::Drop
        {nil, nil}
      end
    end

    # Three rungs where the caller has five. Clamping down is a loss the caller
    # did not ask for, so it is recorded rather than done quietly.
    private def level_for(request : Reasoning::Request,
                          report : Capability::Report) : String?
      asked = case request
              in Reasoning::Effort then request
              in Reasoning::Budget then request.to_effort
              in Reasoning::Off    then return nil
              end

      if asked.x_high? || asked.max?
        report.record(MPSH::Outcome::Degraded,
          "reasoning control: #{asked.wire_name} clamped to the highest rung this protocol spells")
      end
      REASONING_LEVELS[asked]
    end

    # `model`, not `assistant`. The single most common source of a silently
    # wrong mapping on this protocol.
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

      # The signature is replayed when we have one, same as `thinking()` does
      # for Anthropic — but nothing here yet answers what happens when we
      # don't and Gemini 3 requires one. That's `Resolver` work, not this
      # method's; see `spec/live/gemini_spec.cr` for whether plumbing this
      # through is sufficient on its own before that gets designed.
      signature = block.meta_for(profile.metadata_key).try(&.["thought_signature"]?).try(&.as?(String))
      Wire::FunctionCallPart.new(block.name, block.arguments.to_json, signature)
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
