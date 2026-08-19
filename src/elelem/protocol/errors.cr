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
