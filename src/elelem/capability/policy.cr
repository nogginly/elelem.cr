require "../mpsh/annotation"

module Elelem::Capability
  # Which outcomes a session is willing to accept. A session-level policy, never
  # a mapper's judgement call.
  enum Policy
    Strict       # nothing worse than Restructured
    Compensating # Compensated allowed; Degraded is not
    Lenient      # Degraded allowed, each occurrence recorded

    def worst_allowed : MPSH::Outcome
      case self
      in Strict       then MPSH::Outcome::Restructured
      in Compensating then MPSH::Outcome::Compensated
      in Lenient      then MPSH::Outcome::Degraded
      end
    end

    def permits?(outcome : MPSH::Outcome) : Bool
      outcome <= worst_allowed
    end
  end

  # Refusal is a real outcome and it is loud. The alternative to explicit
  # outcomes is not refusal — it is silence, and silence is a model answering
  # confidently about content it never received.
  class RefusedError < Exception
    getter outcome : MPSH::Outcome
    getter provider : String
    getter block_kind : MPSH::BlockKind?

    def initialize(@provider : String, detail : String,
                   @block_kind : MPSH::BlockKind? = nil,
                   @outcome : MPSH::Outcome = MPSH::Outcome::Refused)
      super("#{@provider}: #{detail}")
    end
  end

  # Accompanies every mapping. Annotations collected here are copied onto the
  # session by the client layer; synthesized content is *not* here, because
  # synthesized content is not anywhere except the outgoing request.
  class Report
    getter provider : String
    getter policy : Policy
    getter annotations : Array(MPSH::Annotation)

    def initialize(@provider : String, @policy : Policy = Policy::Compensating)
      @annotations = [] of MPSH::Annotation
      @worst = MPSH::Outcome::Exact
      @reasoning_dropped = 0
    end

    getter worst : MPSH::Outcome

    # Reasoning blocks omitted because the caller asked for it. A plain count,
    # deliberately *not* an annotation: this is requested trimming, not damage,
    # and the annotation channel is only useful while it means the latter.
    property reasoning_dropped : Int32

    # Whether the reply actually arrived as a stream.
    #
    # A plain fact for the same reason `reasoning_dropped` is a plain count,
    # and the reasoning is worth spelling out because the obvious alternative
    # is actively broken. Annotating a fallback would call `record`, `record`
    # raises on anything the policy disallows, and `Degraded` is disallowed
    # under both `Strict` and the default `Compensating` — so "this deployment
    # did not stream" would refuse the request outright.
    #
    # It would also be a category error. Streaming is not a fidelity axis at
    # all: a streamed reply and a non-streamed one are the *same*
    # `MPSH::Message` by construction, since they meet at `export_reply` having
    # differed only as far as the wire type. Nothing is lost by not streaming,
    # so there is nothing for the annotation channel to record — and putting a
    # transport preference in the channel that means silent damage is precisely
    # what `ReasoningRetention`'s own comment warns against.
    property? streamed : Bool = false

    # Single funnel: every mapper reports every outcome here, and this is where
    # policy is enforced. A mapper that wants to lose something has to say so.
    def record(outcome : MPSH::Outcome, detail : String,
               message_index : Int32? = nil, block_kind : MPSH::BlockKind? = nil) : MPSH::Outcome
      @worst = outcome if outcome > @worst

      unless policy.permits?(outcome)
        raise RefusedError.new(provider, "#{detail} (#{outcome} exceeds policy #{policy})", block_kind, outcome)
      end

      if outcome.lossy? || outcome.synthesizes?
        @annotations << MPSH::Annotation.new(outcome, provider, detail, message_index, block_kind)
      end
      outcome
    end
  end
end
