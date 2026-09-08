require "./block"

module Elelem::MPSH
  # Two roles. `system`, `developer`, `tool` and `model` are provider spellings
  # and are resolved at map time, in both directions.
  enum Role
    User
    Assistant
  end

  # How a turn finished. Canonical, because a session reloaded in another
  # process must still know its last turn was cut — a `Capability::Report` is
  # per-call and is never archived.
  #
  # Deliberately *settable* rather than derived. Three of the four causes have a
  # vendor field behind them and could be normalised from `provider_metadata`;
  # the fourth has nothing to read at all, since a dropped stream carries the
  # fact as the *absence* of a terminal frame. A design that could only derive
  # could not express it.
  #
  # The cause is kept because it decides the caller's next move — await input,
  # back off, retry — not because repair differs. Repair is identical for all
  # three non-`Complete` members.
  enum Ending
    Complete    # the model finished
    Truncated   # the model stopped short: an output cap, a resource limit
    Stopped     # the caller asked, through `Streaming::Turn#stop`
    Interrupted # the stream ended without its terminal frame

    # Whether the turn needs `Repair` before the session is built on again.
    def cut? : Bool
      !complete?
    end
  end

  # Who produced an assistant turn. Historical only — it never influences mapping.
  struct Provenance
    getter provider : String
    getter model : String
    getter bias : String?

    def initialize(@provider : String, @model : String, @bias : String? = nil)
    end
  end

  class Message
    include ProviderScoped

    getter role : Role
    getter content : Array(Block)
    getter provenance : Provenance?

    # `Complete` unless something says otherwise: an exporter reading its
    # protocol's own stop reason, or `Client` observing how a stream ended.
    property ending : Ending = Ending::Complete

    def initialize(@role : Role, @content : Array(Block) = [] of Block,
                   @provenance : Provenance? = nil)
    end

    def self.user(text : String)
      new(Role::User, [TextBlock.new(text).as(Block)])
    end

    def self.assistant(text : String, provenance : Provenance? = nil)
      new(Role::Assistant, [TextBlock.new(text).as(Block)], provenance)
    end

    def text : String
      content.compact_map { |block| block.as?(TextBlock).try &.text }.join("\n\n")
    end
  end
end
