require "../mpsh/annotation"
require "../mpsh/meta"

module Elelem::Streaming
  # What a caller may watch while a reply is being generated.
  #
  # **Events are presentation; the session is state.** `DEVELOPMENT.md` governs
  # this and it is not restated here, but the consequence for this file is
  # concrete: nothing below is authoritative. Text arriving in three chunks is
  # three events and one `TextBlock`. A caller that accumulates events into a
  # reply has reimplemented the exporter, worse, and will diverge from it.
  #
  # **A closed union, like `MPSH::Block`.** `alias`ed over the variants so
  # `case event; in TextDelta` is exhaustiveness-checked, which means a sixth
  # variant breaks every consumer until each says what it does. That is the
  # intent, and it is the reason the set below was chosen deliberately rather
  # than grown: adding to it later is expensive on purpose.
  #
  # **There is no terminal event.** Whether the model stopped or wants a tool
  # is a fact about the reply, not about the stream. An event saying so would
  # tempt every caller to branch on the thing that is not authoritative, which
  # is the failure this whole arrangement is arranged against.

  # A fragment of the assistant's answer.
  struct TextDelta
    getter text : String

    def initialize(@text : String)
    end
  end

  # A fragment of the model's reasoning.
  #
  # **Emitted under every `Capability::ReasoningRetention` setting**, including
  # `None`, and the reason is not a judgement call. Retention is applied in
  # exactly one place — `Capability::Retention.plan`, called from the four
  # `Mapper#map` implementations — so under `None` a reply's `ReasoningBlock`
  # is still exported into the `MPSH::Message` and still handed to the caller.
  # Retention drops reasoning on the way *out*, next turn. An event stream that
  # omitted what the accompanying reply contains would be a false account of
  # the turn.
  #
  # Whether a person *sees* this is a display decision belonging to whatever is
  # doing the displaying. The CLI answers it with `--show-reasoning`,
  # defaulting off. See `SCOPE.md`'s *Retention governs replay, not display and
  # not storage*.
  struct ReasoningDelta
    getter text : String

    def initialize(@text : String)
    end
  end

  # The model has begun requesting a tool.
  #
  # **Carries the name and nothing else, deliberately.** No identifier, no
  # arguments, not even a partial. A caller cannot dispatch from this and
  # cannot accumulate a call out of it, which is the point: tool calls are read
  # off the reply, and an event rich enough to act on would quietly invite the
  # other thing. What this is for is telling someone waiting that the pause
  # they are looking at is a tool call rather than a stall.
  struct ToolCallStarted
    getter name : String

    def initialize(@name : String)
    end
  end

  # A fidelity annotation, delivered live rather than only post-hoc in the
  # `Report`.
  #
  # Every annotation in a turn already exists before the first frame arrives —
  # mapping happens in `Adapter#prepare`, and the report is complete by the
  # time anything is sent. So these are emitted at the head of the stream. That
  # is not a limitation to be fixed later: it is what "the request was degraded
  # before it left" honestly looks like on a timeline, and delaying them to the
  # end would be the misleading version.
  struct AnnotationRaised
    getter annotation : MPSH::Annotation

    def initialize(@annotation : MPSH::Annotation)
    end
  end

  # Something a provider streams that has no canonical equivalent.
  #
  # Namespaced by vendor, exactly as `provider_metadata` is, so a consumer
  # reads only the vendor it understands and everything else is inert. The
  # escape hatch exists so that a protocol emitting something interesting does
  # not force a sixth variant onto the closed union — and unlike a
  # stringly-typed tuple, this one has an inverse: `MPSH::Object` is the same
  # type the metadata channel already carries.
  struct ProviderDelta
    getter vendor : String
    getter data : MPSH::Object

    def initialize(@vendor : String, @data : MPSH::Object)
    end
  end

  alias Event = TextDelta |
                ReasoningDelta |
                ToolCallStarted |
                AnnotationRaised |
                ProviderDelta
end
