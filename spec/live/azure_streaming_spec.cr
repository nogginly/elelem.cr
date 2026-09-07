require "../spec_helper"

# Streaming against Azure OpenAI, on both protocols it serves.
#
# **Why Azure separately at all.** It is the same two protocols, so most of the
# shape is already proven — but Azure is the one deployment that has already
# been caught diverging from the endpoint it reimplements: `max_tokens` is
# rejected in favour of `max_completion_tokens` for reasoning models, which is
# why `Wire::MaxTokensField` exists and why `Provider.for_azure` takes it. A
# deployment that diverges once is worth asking twice.
#
# **The specific thing streaming adds.** Azure prepends a chunk carrying
# `prompt_filter_results` with an **empty `choices` array**, and may attach
# `content_filter_results` to later chunks. The assembler returns early when a
# chunk has no choice, so filter chunks should pass through inert — but
# "should" is doing the work in that sentence, and an empty-`choices` chunk is
# also exactly the shape `stream_options.include_usage` uses. If the two were
# confused, usage would be read from a filter chunk or thrown away with one.
#
# **Two paid calls**, one per protocol, both tiny. Nothing here re-tests what
# Ollama and OpenAI already proved about the protocols themselves; these ask
# only whether this deployment's extra chunks are harmless and whether its
# streamed shape holds.
private ENDPOINT    = "https://oxaro-alpha.openai.azure.com"
private DEPLOYMENT  = "gpt5.4mini"
private API_VERSION = "2025-04-01-preview"

private STREAM_CHAT      = "azure_chat_completions_stream"
private STREAM_RESPONSES = "azure_responses_stream"

private def azure : Elelem::Server
  Elelem::Server.new("azure", ENDPOINT, ENV["AZURE_OPENAI_API_KEY"]?)
end

private def client(protocol : Elelem::ProtocolKind) : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for_azure(azure, protocol, API_VERSION,
    max_tokens_field: protocol.chat_completions? ? Elelem::Protocol::ChatCompletions::Wire::MaxTokensField::MaxCompletionTokens : nil))
end

private CAP = Elelem::Options.new(max_output_tokens: 256)

private def asked : M::Session
  session = M::Session.new("You are terse.")
  session << M::Message.user("Say hello in one short sentence.")
  session
end

describe "Azure OpenAI streaming" do
  describe "Chat Completions" do
    it "streams a reply the filter chunks do not disturb" do
      # If `prompt_filter_results` were mistaken for a choice-bearing chunk,
      # the symptom would be a raise or a truncated reply rather than anything
      # subtle — so an ordinary reply arriving is the assertion.
      Wiretap.intercept(STREAM_CHAT) do
        reply, report = client(Elelem::ProtocolKind::ChatCompletions)
          .send(asked, DEPLOYMENT, options: CAP) { |_, _| }

        reply.content.select(M::TextBlock).should_not be_empty
        report.streamed?.should be_true
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "reads usage from the usage chunk, not from a filter chunk" do
      # Both arrive with an empty `choices` array, which is the whole hazard.
      # A token count that is present and plausible is the evidence they were
      # told apart; a filter chunk read as usage would yield nil or nonsense.
      Wiretap.intercept(STREAM_CHAT) do
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions)
          .send(asked, DEPLOYMENT, options: CAP) { |_, _| }

        key = Elelem::Protocol::ChatCompletions::METADATA_KEY
        usage = reply.meta?(key, "usage").should_not be_nil
        usage.as(M::Object).has_key?("total_tokens").should be_true
      end
    end

    it "terminates properly" do
      Wiretap.intercept(STREAM_CHAT) do
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions)
          .send(asked, DEPLOYMENT, options: CAP) { |_, _| }

        key = Elelem::Protocol::ChatCompletions::METADATA_KEY
        reply.meta?(key, "finish_reason").should_not be_nil
      end
    end

    it "folds many fragments into one text block" do
      Wiretap.intercept(STREAM_CHAT) do
        seen = [] of S::Event
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions)
          .send(asked, DEPLOYMENT, options: CAP) { |event, _| seen << event }

        deltas = seen.select(S::TextDelta)
        deltas.should_not be_empty
        deltas.size.should be > reply.content.select(M::TextBlock).size
      end
    end
  end

  describe "Responses" do
    it "streams a reply from the deployment-scoped path" do
      # Azure's Responses path has no deployment segment, which was confirmed
      # against a real resource rather than assumed. Streaming uses the same
      # path — there is no `stream_path` override here — so a wrong URL would
      # surface as a transport error.
      Wiretap.intercept(STREAM_RESPONSES) do
        reply, report = client(Elelem::ProtocolKind::Responses)
          .send(asked, DEPLOYMENT, options: CAP) { |_, _| }

        reply.content.select(M::TextBlock).should_not be_empty
        report.streamed?.should be_true
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "delivers finished items whole, as OpenAI's own endpoint does" do
      # The property partial replies depend on, and the one an emulating or
      # wrapping deployment could most plausibly drop. Asserted the same way it
      # was for Ollama, so a difference between the two shows up as a
      # difference in this line rather than in prose.
      Wiretap.intercept(STREAM_RESPONSES) do
        seen = [] of S::Event
        reply, _ = client(Elelem::ProtocolKind::Responses)
          .send(asked, DEPLOYMENT, options: CAP) { |event, _| seen << event }

        seen.select(S::TextDelta).should_not be_empty
        reply.content.select(M::TextBlock).size.should eq 1
      end
    end
  end
end
