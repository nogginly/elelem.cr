require "../../capability/profile"
require "../../reasoning"

module Elelem::Protocol::Anthropic
  METADATA_KEY = "anthropic"
  NAME         = "anthropic"

  # Required by the protocol with no default. A caller may override per request.
  DEFAULT_MAX_TOKENS = 4096

  # Sent as `anthropic-version` on every request; the endpoint rejects calls
  # without it. Pinned rather than tracking latest, because a version bump can
  # change response shapes and this shard's readers are written against this
  # one.
  API_VERSION = "2023-06-01"

  # The API rejects a smaller budget outright.
  MIN_THINKING_BUDGET = 1024

  # A named rung rendered as a token budget, for the deployments that take a
  # budget and nothing else.
  #
  # This is the mapping the resolver calls **Restructured** rather than
  # Degraded, and the reason is that it is not ours: this vendor presents the
  # same five rungs on its own product, so expressing one as a budget adopts an
  # abstraction the vendor already publishes instead of guessing at an
  # equivalence. The figures follow its own tuning guidance — start near the
  # 1,024 floor for simple work, 16,000 or more for complex, and prefer batch
  # processing beyond 32,000, which is why nothing here reaches past it.
  #
  # `Max` means "no constraint", which has no fixed number: it resolves to just
  # under the request's own output cap, since a budget must always leave room
  # for the answer.
  REASONING_BUDGETS = {
    Reasoning::Effort::Low    => 1024,
    Reasoning::Effort::Medium => 4096,
    Reasoning::Effort::High   => 16_000,
    Reasoning::Effort::XHigh  => 32_000,
    Reasoning::Effort::Max    => Int32::MAX,
  }

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
    # Both, and which one depends on the model rather than the protocol.
    # `thinking.budget_tokens` is the only mode on Claude 4.5 and earlier,
    # deprecated on 4.6, and **rejected with a 400 from 4.7 onward**, where the
    # control moved to `output_config.effort` alongside adaptive thinking.
    # `Either` is therefore the honest protocol-level declaration; `Catalog`
    # resolves it per model, and guessing would be a rejected request rather
    # than a recorded loss.
    reasoning_unit: Capability::ReasoningUnit::Either,
    tool_calls: Capability::ToolCallForm::Block,
    tool_results: Capability::ToolResultForm::Blocks,
    server_executed: true,
    refusal_channel: false,
    can_synthesize_user_message: true,
    alternation_required: true,
    first_message_must_be_user: true,
    system_placement: Capability::SystemPlacement::Parameter,
    string_shorthand: true,
    # Confirmed live, not assumed: a `thinking` block with no `signature` is
    # a 400 here — `messages.N.content.M.thinking.signature: Field required`
    # — regardless of where the block came from. See `spec/live/anthropic_spec.cr`.
    reasoning_signature_required: true
  )
end
