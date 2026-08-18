require "./block"

module Elelem::MPSH
  # The five outcomes, ordered by fidelity. The ordering is load-bearing:
  # a degradation policy is expressed as "nothing worse than X", which is a
  # comparison, not a table.
  enum Outcome
    Exact        # native support, direct translation
    Restructured # same information, different shape
    Compensated  # meaning preserved by synthesizing messages; never stored
    Degraded     # information lost, substitute used; recorded
    Refused      # cannot map; fail loudly, send nothing

    def lossy?
      self >= Degraded
    end

    def synthesizes?
      self == Compensated
    end
  end

  # Off-path metadata. Annotations are *not* conversation content: they never
  # enter the linearization path and are never sent to a provider. They exist so
  # a session's fidelity history is auditable after the fact — the answer to a
  # mature client that stores tool-result images faithfully and then silently
  # drops them on the wire.
  struct Annotation
    getter outcome : Outcome
    getter provider : String
    getter detail : String
    getter message_index : Int32?
    getter block_kind : BlockKind?
    getter at : Time

    def initialize(@outcome : Outcome, @provider : String, @detail : String,
                   @message_index : Int32? = nil, @block_kind : BlockKind? = nil,
                   @at : Time = Time.utc)
    end

    def to_s(io : IO) : Nil
      io << outcome << " [" << provider << "] " << detail
      if k = block_kind
        io << " (" << k << ")"
      end
    end
  end
end
