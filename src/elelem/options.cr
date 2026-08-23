require "json"
require "./reasoning"

module Elelem
  # A tool the model may call.
  #
  # `parameters` is a JSON Schema as **text**, not a parsed structure. That is
  # deliberate: a schema's natural interchange form is JSON, it arrives that
  # way from MCP servers and configuration files, and a caller who generates
  # one from a Crystal type can hand over the result without this shard needing
  # to know how it was produced.
  #
  # Callers wanting compile-time schemas can pair this with a generator — for
  # example `spider-gazelle/json-schema`:
  #
  # ```
  # Tool.new("get_weather", "Look up the weather",
  #   GetWeatherParams.json_schema.to_json)
  # ```
  #
  # That shard stays *their* dependency, not ours. Taking it here would make
  # every consumer carry it, and would force a Crystal type on callers whose
  # schema arrives as text — the common case.
  #
  # Note that tools are not session history. They are what the caller offers on
  # *this* call, which is why they live in `Options` and not in `Session`: a
  # stored conversation that carried its own tool list would have acquired a
  # home, and portability is exactly the thing this shard refuses to give up.
  struct Tool
    getter name : String
    getter description : String?
    getter parameters : String

    EMPTY_SCHEMA = %({"type":"object","properties":{}})

    def initialize(@name : String, @description : String? = nil,
                   @parameters : String = EMPTY_SCHEMA)
      raise ArgumentError.new("tool name cannot be empty") if @name.empty?
    end
  end

  # What the caller wants of *this* request, as opposed to what the session
  # remembers.
  #
  # Kept apart from `policy` and `retention`, which are fidelity controls —
  # they govern what may be lost in translating history. These govern what the
  # model is asked to do next. Two different questions that happen to travel on
  # the same call.
  #
  struct Options
    getter tools : Array(Tool)

    # The one generation parameter every protocol can express, in four
    # spellings. Absent means "whatever the provider defaults to", which on a
    # local endpoint can mean a model reasoning until something gives — a
    # failure this suite has already met.
    getter max_output_tokens : Int32?

    # How hard to think, in whichever of two units the caller prefers. Unlike
    # the output cap, this is the one request option no two protocols agree
    # about: three take a named rung, two take a token budget, and the ones
    # that take both reject being given both.
    #
    # **Absent means absent.** Nothing is emitted on any protocol, and the
    # provider's own default stands. That is load-bearing rather than tidy: it
    # keeps every request body that does not ask for reasoning byte-identical
    # to what it was before this option existed, so no recorded transcript is
    # re-cut by adding it.
    getter reasoning : Reasoning::Request?

    def initialize(@tools : Array(Tool) = [] of Tool,
                   @max_output_tokens : Int32? = nil,
                   @reasoning : Reasoning::Request? = nil)
    end

    def tools? : Bool
      !@tools.empty?
    end
  end
end
