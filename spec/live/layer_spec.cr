require "../spec_helper"
require "../fixtures/response_fixtures"

# The live layer, tested without a network.
#
# Everything here is a pure function of a provider, an adapter or a status
# code. `Client#transmit` is the only method in the layer that touches HTTP,
# which is what leaves the rest of it testable this way — and what makes the
# wiretap suite next door a test of the *wire*, not of this logic.
#
# The narrowing specs matter most. Ollama cannot exercise them: it ignores
# signatures, so a correctly pessimistic provider and a wrongly optimistic one
# both produce a green live run. The divergence is only observable here, in
# the mapper, which is why these are offline by necessity rather than by
# convenience.
private alias RF = Elelem::ResponseFixtures

private def signed_session : M::Session
  session = M::Session.new("You are terse.")
  session << M::Message.user("What is the tallest mountain?")

  anthropic = Elelem::Protocol::Anthropic::Mapper.new
  session << Elelem::Protocol::Anthropic::Exporter.new(anthropic.calls)
    .export_reply(RF::ANTHROPIC_THINKING)
  session << M::Message.user("And the deepest ocean?")
  session
end

# Request wire types are serialize-only by design — the direction that reads
# is `wire/response.cr`. So the built body is inspected as JSON rather than
# parsed back into wire structs, which would need a reader that exists for no
# other reason.
private def thinking_parts(body : String) : Array(JSON::Any)
  JSON.parse(body)["messages"].as_a.flat_map do |message|
    content = message["content"]?
    next [] of JSON::Any unless content && content.as_a?
    content.as_a.select { |block| block["type"]?.try(&.as_s?) == "thinking" }
  end
end

describe "the live layer" do
  describe "vendor narrowing" do
    # A server whose own name matches the protocol's vendor is that vendor, and
    # inherits its authenticity. No flag; the default falls out of comparing
    # names.
    it "treats a vendor's own server as authentic" do
      server = Elelem::Server.new("anthropic", "https://api.anthropic.com")
      provider = Elelem::Provider.for(server, Elelem::ProtocolKind::Anthropic)

      provider.profile.metadata_key.should eq "anthropic"
    end

    # The case this exists for. Ollama serving an Anthropic-compatible endpoint
    # is not Anthropic: a signature minted by Claude means nothing to it.
    it "narrows a compatibility endpoint away from the protocol's vendor" do
      server = Elelem::Server.new("ollama", "http://localhost:11434")
      provider = Elelem::Provider.for(server, Elelem::ProtocolKind::Anthropic)

      provider.profile.metadata_key.should eq "ollama"
      # Narrowing touches only the vendor axis. The protocol is unchanged.
      provider.profile.provider.should eq "anthropic"
      provider.profile.reasoning.should eq C::ReasoningForm::Block
    end

    # The consequence, and the reason the default is pessimistic. Replaying a
    # signature to an endpoint that cannot validate it risks a rejected turn;
    # withholding it costs fidelity, which is recoverable and recorded.
    #
    # Note what is *not* withheld: the thinking text travels. Narrowing sheds
    # the opaque payload by namespacing, not by dropping the block — which is
    # why this is `Restructured` rather than a loss, and why `strict` does not
    # refuse a cross-provider handoff of a reasoning session.
    it "withholds a foreign signature but keeps the reasoning it explains" do
      session = signed_session
      ollama = Elelem::Provider.for(
        Elelem::Server.new("ollama", "http://localhost:11434"),
        Elelem::ProtocolKind::Anthropic)

      exchange = ollama.adapter.prepare(session, "llama3.2",
        C::Policy::Lenient, C::ReasoningRetention::All, 1024)

      blocks = thinking_parts(exchange.body)
      blocks.size.should eq 1
      blocks[0]["thinking"].as_s.should contain "Everest"
      blocks[0]["signature"]?.should be_nil

      exchange.report.worst.should be >= M::Outcome::Restructured
    end

    it "replays the signature to the vendor's own endpoint" do
      session = signed_session
      anthropic = Elelem::Provider.for(
        Elelem::Server.new("anthropic", "https://api.anthropic.com"),
        Elelem::ProtocolKind::Anthropic)

      exchange = anthropic.adapter.prepare(session, "claude-sonnet-4-6",
        C::Policy::Lenient, C::ReasoningRetention::All, 1024)

      blocks = thinking_parts(exchange.body)
      blocks.size.should eq 1
      blocks[0]["signature"]?.try(&.as_s?).should_not be_nil
    end

    # Overriding is for gateways that pass opaque data through untouched. It is
    # a claim about someone else's infrastructure, hence deliberate.
    it "lets a gateway claim the upstream vendor explicitly" do
      gateway = Elelem::Provider.for(
        Elelem::Server.new("openrouter", "https://openrouter.ai"),
        Elelem::ProtocolKind::Anthropic, vendor: "anthropic")

      gateway.profile.metadata_key.should eq "anthropic"

      exchange = gateway.adapter.prepare(signed_session, "claude-sonnet-4-6",
        C::Policy::Lenient, C::ReasoningRetention::All, 1024)

      thinking_parts(exchange.body).size.should eq 1
    end

    # Narrowing is one-directional by construction: there is no way to widen a
    # profile beyond what the protocol declares. A misconfigured provider can
    # only ever degrade — never fabricate a capability the wire lacks.
    it "cannot widen a protocol beyond what it declares" do
      chat = Elelem::Provider.for(
        Elelem::Server.new("ollama", "http://localhost:11434"),
        Elelem::ProtocolKind::ChatCompletions, vendor: "anthropic")

      # Claiming Anthropic's vendor over Chat Completions does not grant
      # Anthropic's capabilities.
      chat.profile.tool_results.should eq SpecHelpers::CHAT.tool_results
      chat.profile.reasoning.should eq SpecHelpers::CHAT.reasoning
      chat.profile.server_executed?.should eq SpecHelpers::CHAT.server_executed?
    end
  end

  describe "paths" do
    it "posts to each protocol's endpoint" do
      Elelem::ChatCompletionsAdapter.new.path("llama3.2").should eq "/v1/chat/completions"
      Elelem::ResponsesAdapter.new.path("gpt-4.1").should eq "/v1/responses"
      Elelem::AnthropicAdapter.new.path("claude-sonnet-4-6").should eq "/v1/messages"
    end

    # Gemini is the only protocol that puts the model in the path rather than
    # the body, which is the whole reason `path` takes a model at all.
    it "puts the model in the path for Gemini" do
      Elelem::GeminiAdapter.new.path("gemini-2.0-flash")
        .should eq "/v1beta/models/gemini-2.0-flash:generateContent"
    end

    it "escapes a model name that would otherwise break the path" do
      Elelem::GeminiAdapter.new.path("models/weird name")
        .should contain "weird%20name"
    end
  end

  describe "headers" do
    it "sends a bearer token on the OpenAI protocols" do
      Elelem::ChatCompletionsAdapter.new.headers("sk-test")["authorization"]
        .should eq "Bearer sk-test"
      Elelem::ResponsesAdapter.new.headers("sk-test")["authorization"]
        .should eq "Bearer sk-test"
    end

    # Both are required: the endpoint rejects a request with no version header,
    # and the version is pinned because a bump can change response shapes the
    # readers are written against.
    it "sends the api key and the pinned version on Anthropic" do
      headers = Elelem::AnthropicAdapter.new.headers("sk-ant-test")

      headers["x-api-key"].should eq "sk-ant-test"
      headers["anthropic-version"].should eq Elelem::Protocol::Anthropic::API_VERSION
    end

    # Header rather than the `?key=` query parameter: a credential in a URL
    # ends up in logs and proxy traces.
    it "keeps the Gemini key out of the URL" do
      Elelem::GeminiAdapter.new.headers("goog-test")["x-goog-api-key"]
        .should eq "goog-test"
    end

    # Ollama needs no credential, and a missing one must not become the string
    # "Bearer ".
    it "omits auth entirely when there is no credential" do
      Elelem::ChatCompletionsAdapter.new.headers(nil)["authorization"]?.should be_nil
      Elelem::AnthropicAdapter.new.headers(nil)["x-api-key"]?.should be_nil
      Elelem::GeminiAdapter.new.headers(nil)["x-goog-api-key"]?.should be_nil
    end

    it "always declares JSON" do
      [Elelem::ChatCompletionsAdapter.new, Elelem::ResponsesAdapter.new,
       Elelem::AnthropicAdapter.new, Elelem::GeminiAdapter.new].each do |adapter|
        adapter.headers(nil)["content-type"].should eq "application/json"
      end
    end
  end

  describe "error classification" do
    server = Elelem::Server.new("ollama", "http://localhost:11434")

    it "distinguishes the failures a caller would act on differently" do
      server.error_for(401).should be_a Elelem::AuthError
      server.error_for(403).should be_a Elelem::AuthError
      server.error_for(404).should be_a Elelem::ModelNotFoundError
      server.error_for(429).should be_a Elelem::RateLimitedError
      server.error_for(503).should be_a Elelem::OverloadedError
      server.error_for(400).should be_a Elelem::TransportError
    end

    # Retry logic does not exist yet. When it does, this is the question it
    # will ask, so the answer is pinned now rather than guessed then.
    it "marks only the failures worth waiting on as transient" do
      server.error_for(429).transient?.should be_true
      server.error_for(500).transient?.should be_true
      server.error_for(400).transient?.should be_false
      server.error_for(401).transient?.should be_false
    end

    it "names the server that failed" do
      server.error_for(500).server.should eq "ollama"
    end

    # A status alone tells a caller nothing about which block the endpoint
    # objected to. The provider's own words are the useful part.
    it "surfaces the provider's message from the error body" do
      body = %({"error": {"message": "model 'nope' not found", "type": "invalid_request"}})

      Elelem::ChatCompletionsAdapter.new.error_detail(body)
        .should eq "model 'nope' not found"
      Elelem::AnthropicAdapter.new.error_detail(body)
        .should eq "model 'nope' not found"
      Elelem::GeminiAdapter.new.error_detail(body)
        .should eq "model 'nope' not found"
    end

    # A compatibility layer returning a plausible status with an implausible
    # body must not turn into a parse crash on top of the original failure.
    it "gives up quietly on an error body it cannot read" do
      adapter = Elelem::ChatCompletionsAdapter.new

      adapter.error_detail("<html>502 Bad Gateway</html>").should be_nil
      adapter.error_detail("").should be_nil
      adapter.error_detail(%({"unexpected": true})).should be_nil
    end
  end

  describe "the exchange seam" do
    # `prepare` builds a body, the server sends it, `read` turns the reply into
    # a message. Three steps rather than one, so streaming can later slot
    # between the second and third — and so everything except the middle step
    # is testable with no network.
    it "reads a recorded reply through a prepared exchange" do
      provider = Elelem::Provider.for(
        Elelem::Server.new("ollama", "http://localhost:11434"),
        Elelem::ProtocolKind::ChatCompletions)

      session = M::Session.new("You are terse.")
      session << M::Message.user("What is the tallest mountain?")

      exchange = provider.adapter.prepare(session, "llama3.2",
        C::Policy::Compensating, C::ReasoningRetention::All, 4096)

      exchange.body.should contain "llama3.2"
      # Chat Completions carries the system prompt as a message, where MPSH
      # holds it as a session field — `MoveSystemPrompt`, and Restructured by
      # design. Any session with a system prompt is Restructured here, so
      # Exact was never on offer.
      exchange.report.worst.should eq M::Outcome::Restructured

      reply = exchange.read(RF::CHAT_TEXT)
      reply.role.should eq M::Role::Assistant
      reply.content[0].as(M::TextBlock).text.should contain "Everest"
    end

    # The pairing is structural: `read` closes over an exporter built from the
    # mapper's own table, so a call minted on the way out is recognised on the
    # way back with nothing for a caller to remember.
    it "pairs the exporter with the mapper that built the request" do
      provider = Elelem::Provider.for(
        Elelem::Server.new("ollama", "http://localhost:11434"),
        Elelem::ProtocolKind::ChatCompletions)

      session = M::Session.new("You are terse.")
      session << M::Message.user("Weather in Paris and Bogota?")

      exchange = provider.adapter.prepare(session, "llama3.2",
        C::Policy::Compensating, C::ReasoningRetention::All, 4096)
      reply = exchange.read(RF::CHAT_TOOL_CALL)

      calls = reply.content.select(M::ToolCallBlock)
      calls.size.should eq 2
      calls[0].call_id.should_not eq calls[1].call_id
    end
  end

  describe "provider defaults" do
    it "carries a per-provider max_tokens" do
      provider = Elelem::Provider.for(
        Elelem::Server.new("anthropic", "https://api.anthropic.com"),
        Elelem::ProtocolKind::Anthropic, default_max_tokens: 2048)

      provider.default_max_tokens.should eq 2048
    end

    # A deployment fact most of the time, a request fact occasionally.
    it "lets a call override the provider default" do
      adapter = Elelem::AnthropicAdapter.new("anthropic")
      session = M::Session.new
      session << M::Message.user("Hello")

      exchange = adapter.prepare(session, "claude-sonnet-4-6",
        C::Policy::Compensating, C::ReasoningRetention::All, 512)

      JSON.parse(exchange.body)["max_tokens"].as_i.should eq 512
    end
  end
end
