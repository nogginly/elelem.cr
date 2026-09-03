module Elelem::Protocol
  # A response body that cannot be read as this protocol's shape.
  #
  # Deliberately not a `Capability::RefusedError`. Refusal is a *fidelity*
  # outcome — the mapping is impossible and the capability model says so. This
  # is the transport failing: a truncated body, an error object where a reply
  # was expected, a provider that answered in some other protocol's shape.
  # Conflating them would put a network fault into the fidelity record.
  #
  # Parsing is otherwise deliberately tolerant. Unknown fields are ignored,
  # because providers add them constantly and a strict reader would break on
  # every vendor tweak. Only a body whose *required* shape is absent raises.
  class MalformedResponseError < Exception
    getter provider : String

    def initialize(@provider : String, detail : String)
      super("#{@provider}: #{detail}")
    end
  end
end

module Elelem::Protocol
  # A response body that cannot be read as this protocol's shape.
  #
  # Deliberately not a `Capability::RefusedError`. Refusal is a *fidelity*
  # outcome — the mapping is impossible and the capability model says so. This
  # is the transport failing: a truncated body, an error object where a reply
  # was expected, a provider that answered in some other protocol's shape.
  # Conflating them would put a network fault into the fidelity record.
  #
  # Parsing is otherwise deliberately tolerant. Unknown fields are ignored,
  # because providers add them constantly and a strict reader would break on
  # every vendor tweak. Only a body whose *required* shape is absent raises.
  class MalformedResponseError < Exception
    getter provider : String

    def initialize(@provider : String, detail : String)
      super("#{@provider}: #{detail}")
    end
  end

  # A streamed generation that failed after the response had already begun.
  #
  # **Here rather than beside `TransportError`, and not a subclass of it.**
  # Once the outer status is committed at 200 there is no status left to
  # describe the failure, so a mid-stream failure arrives as an error frame in
  # place of the terminal one — or as nothing at all, the body simply stopping.
  # Inheriting from `TransportError` would bring `status` along, and `status`
  # would have to lie: either repeating the 200 that succeeded or inventing a
  # code the server never sent. It would also inherit `transient?`, whose whole
  # distinction is the one being lost — a 429 is worth waiting on, this is not.
  #
  # That leaves `MalformedResponseError` as the real sibling, which is where
  # this sits. Its comment already claims the territory: a truncated body, an
  # error object where a reply was expected. A cut stream is that, arriving one
  # frame at a time.
  #
  # `source` rather than `provider`, unlike its sibling, because two layers
  # raise this and they know different things. An assembler reading an error
  # frame names the protocol — it is deliberately server-agnostic, for the same
  # reason exporters are. A client noticing a stream ended early names the
  # deployment, which is the more useful identity when it is available.
  #
  # `type` is the vendor's own name for what went wrong, taken from the frame
  # verbatim. Nullable because a frame may carry no type at all, and inventing
  # one would put a guess where a caller expects a provider's word.
  class StreamError < Exception
    getter source : String
    getter type : String?

    def initialize(@source : String, detail : String, @type : String? = nil)
      super(@type ? "#{@source}: #{@type} — #{detail}" : "#{@source}: #{detail}")
    end
  end
end
