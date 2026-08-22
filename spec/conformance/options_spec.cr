require "../spec_helper"

# Tool declarations and output caps, across four spellings of two ideas.
#
# These are *request* concerns, not session ones. A session that carried its
# own tool list would have acquired a home — the failure this shard exists to
# avoid — so `Options` rides on the call beside `policy` and `retention`, and
# nothing here touches `Session`.
#
# The gap these close was found live, not offline: an uncapped local model spent
# 4,096 tokens reasoning without reaching an answer, and no protocol but
# Anthropic could have stopped it.
private WEATHER_SCHEMA = <<-JSON
  {"type":"object","properties":{"location":{"type":"string","description":"City name"}},"required":["location"]}
  JSON

private def weather : Elelem::Tool
  Elelem::Tool.new("get_weather", "Look up the weather in a city", WEATHER_SCHEMA)
end

private def asked : M::Session
  session = M::Session.new("You are terse.")
  session << M::Message.user("Weather in Paris?")
  session
end

private def body(protocol : Elelem::ProtocolKind, options : Elelem::Options) : JSON::Any
  adapter = case protocol
            in Elelem::ProtocolKind::ChatCompletions then Elelem::ChatCompletionsAdapter.new
            in Elelem::ProtocolKind::Responses       then Elelem::ResponsesAdapter.new
            in Elelem::ProtocolKind::Anthropic       then Elelem::AnthropicAdapter.new
            in Elelem::ProtocolKind::Gemini          then Elelem::GeminiAdapter.new
            end

  exchange = adapter.prepare(asked, "test-model", C::Policy::Compensating,
    C::ReasoningRetention::All, 4096, options)
  JSON.parse(exchange.body)
end

describe "request options" do
  describe "tool declarations" do
    # Chat Completions is the only protocol that nests the declaration inside a
    # `function` object — the same hoisting instinct that puts tool *calls* on
    # the message rather than in the content.
    it "nests the declaration under a function object on Chat Completions" do
      tools = body(Elelem::ProtocolKind::ChatCompletions,
        Elelem::Options.new(tools: [weather]))["tools"].as_a

      tools.size.should eq 1
      tools[0]["type"].as_s.should eq "function"
      tools[0]["function"]["name"].as_s.should eq "get_weather"
      tools[0]["function"]["parameters"]["properties"]["location"].should_not be_nil
    end

    it "keeps the declaration flat on the Responses API" do
      tools = body(Elelem::ProtocolKind::Responses,
        Elelem::Options.new(tools: [weather]))["tools"].as_a

      tools[0]["name"].as_s.should eq "get_weather"
      tools[0]["parameters"]["required"].as_a.map(&.as_s).should eq ["location"]
    end

    # Anthropic names the field after what it constrains rather than what it
    # is: `input_schema`, not `parameters`.
    it "calls the schema input_schema on Anthropic" do
      tools = body(Elelem::ProtocolKind::Anthropic,
        Elelem::Options.new(tools: [weather]))["tools"].as_a

      tools[0]["name"].as_s.should eq "get_weather"
      tools[0]["input_schema"]["type"].as_s.should eq "object"
      tools[0]["parameters"]?.should be_nil
    end

    # Gemini nests twice: declarations inside `functionDeclarations`, inside an
    # entry of `tools`.
    it "double-nests declarations on Gemini" do
      tools = body(Elelem::ProtocolKind::Gemini,
        Elelem::Options.new(tools: [weather]))["tools"].as_a

      tools.size.should eq 1
      declarations = tools[0]["functionDeclarations"].as_a
      declarations.size.should eq 1
      declarations[0]["name"].as_s.should eq "get_weather"
    end

    it "carries the description where one is given" do
      [Elelem::ProtocolKind::Responses, Elelem::ProtocolKind::Anthropic].each do |protocol|
        tools = body(protocol, Elelem::Options.new(tools: [weather]))["tools"].as_a
        tools[0]["description"].as_s.should contain "weather"
      end
    end

    # The schema is emitted exactly as given. Rewriting a caller's schema would
    # be a worse failure than the provider's own error message — particularly
    # on Gemini, which accepts only a restricted OpenAPI subset, so a schema
    # valid elsewhere may be rejected there.
    it "passes the schema through untouched" do
      tools = body(Elelem::ProtocolKind::Responses,
        Elelem::Options.new(tools: [weather]))["tools"].as_a

      tools[0]["parameters"]["properties"]["location"]["description"].as_s
        .should eq "City name"
    end

    it "omits the tools field entirely when none are offered" do
      [Elelem::ProtocolKind::ChatCompletions, Elelem::ProtocolKind::Responses,
       Elelem::ProtocolKind::Anthropic, Elelem::ProtocolKind::Gemini].each do |protocol|
        body(protocol, Elelem::Options.new)["tools"]?.should be_nil
      end
    end

    it "refuses a tool with no name" do
      expect_raises(ArgumentError) { Elelem::Tool.new("") }
    end

    it "defaults to an empty object schema" do
      tool = Elelem::Tool.new("ping")
      JSON.parse(tool.parameters)["type"].as_s.should eq "object"
    end
  end

  describe "output caps" do
    it "spells the cap four ways" do
      options = Elelem::Options.new(max_output_tokens: 256)

      body(Elelem::ProtocolKind::ChatCompletions, options)["max_tokens"].as_i.should eq 256
      body(Elelem::ProtocolKind::Responses, options)["max_output_tokens"].as_i.should eq 256
      body(Elelem::ProtocolKind::Anthropic, options)["max_tokens"].as_i.should eq 256
      # The only protocol to put generation parameters in their own object.
      body(Elelem::ProtocolKind::Gemini, options)["generationConfig"]["maxOutputTokens"]
        .as_i.should eq 256
    end

    # Anthropic requires a value, so it always sends one. The other three omit
    # the field and take the provider's default.
    it "omits the cap where none is asked for, except on Anthropic" do
      options = Elelem::Options.new

      body(Elelem::ProtocolKind::ChatCompletions, options)["max_tokens"]?.should be_nil
      body(Elelem::ProtocolKind::Responses, options)["max_output_tokens"]?.should be_nil
      body(Elelem::ProtocolKind::Gemini, options)["generationConfig"]?.should be_nil
      body(Elelem::ProtocolKind::Anthropic, options)["max_tokens"].as_i.should eq 4096
    end

    # The positional `max_tokens` predates options on this protocol, so it
    # remains the fallback rather than becoming a second way to say the same
    # thing.
    it "lets options override Anthropic's positional default" do
      exchange = Elelem::AnthropicAdapter.new.prepare(asked, "test-model",
        C::Policy::Compensating, C::ReasoningRetention::All, 4096,
        Elelem::Options.new(max_output_tokens: 128))

      JSON.parse(exchange.body)["max_tokens"].as_i.should eq 128
    end
  end

  # Options are a request concern; the session is unchanged by them, and two
  # requests differing only in options must produce the same conversation.
  describe "separation from history" do
    it "does not alter the conversation" do
      plain = body(Elelem::ProtocolKind::ChatCompletions, Elelem::Options.new)
      armed = body(Elelem::ProtocolKind::ChatCompletions,
        Elelem::Options.new(tools: [weather], max_output_tokens: 64))

      armed["messages"].to_json.should eq plain["messages"].to_json
    end
  end
end
