require "./session"

module Elelem::MPSH
  # `mpsh_call_id <-> provider_call_id`, one table per provider conversation.
  #
  # This is the one place the deferred binding layer pokes into Phase 0, and it
  # is unavoidable: exporting a tool call from a wire form needs somewhere to
  # remember that `call_abc` is `mc_17..._3`, or round-trip conformance fails on
  # the very first tool fixture. The table is deliberately shaped as the thing a
  # provider binding will later hold, alongside its session handle, under the
  # same disposable-optimization lifecycle. Nothing else about bindings exists yet.
  class CallIdTable
    getter provider : String

    def initialize(@provider : String)
      @to_provider = {} of String => String
      @to_mpsh = {} of String => String
    end

    def bind(mpsh_id : String, provider_id : String) : Nil
      @to_provider[mpsh_id] = provider_id
      @to_mpsh[provider_id] = mpsh_id
    end

    def provider_id(mpsh_id : String) : String?
      @to_provider[mpsh_id]?
    end

    # Export direction: an unseen provider id gets a freshly minted MPSH id.
    def mpsh_id(provider_id : String) : String
      @to_mpsh[provider_id]? || begin
        minted = Ids.call_id
        bind(minted, provider_id)
        minted
      end
    end

    # Gemini has no ids. The mapper pairs by name and ordering and registers the
    # synthetic key it used, so the export side can find its way back.
    def positional_key(name : String, ordinal : Int32) : String
      "#{name}##{ordinal}"
    end
  end
end
