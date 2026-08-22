require "../spec_helper"

# The live layer against a real server.
#
# Ollama is one deployment speaking three protocols, none of them its own
# vendor — the hostile case, and free to run. Everything here was recorded once
# against a local Ollama and replays from `spec/transcripts` thereafter, so the
# suite stays offline for everyone who did not record it.
#
# **Re-recording.** Transcripts are keyed by a digest of the request body, so
# changing the model, the prompt or anything else the mapper emits will miss on
# replay. Delete the transcript, or run the block with `mode: :always`, with
# Ollama running and the model pulled.
#
# **What this cannot cover.**
#
# - *Tool calls.* No protocol's wire request can declare tools yet, so a model
#   has nothing to call. See `SCOPE.md`.
# - *Vendor authenticity.* Ollama ignores signatures rather than validating
#   them, so a correctly pessimistic provider and a wrongly optimistic one both
#   pass here. Those specs live offline in `layer_spec.cr`, where the
#   divergence is observable.
# - *Auth headers.* Ollama accepts the API key without validating it and
#   accepts `anthropic-version` without using it.
# - *Gemini.* Ollama does not serve it. That protocol's live coverage waits for
#   a Google endpoint.
private MODEL = "gemma4:26b-mxfp8"

# Transcript names.
#
# Several examples read the *same* recorded exchange from different angles, so
# they share a name deliberately: identical request, one recording, one
# generation at record time. Whichever example runs first records and the rest
# replay, which is why random ordering is harmless — none of them depends on
# being first, and each records itself when run alone.
#
# The rule: share a name when the request is byte-identical, never merely to
# save a recording. Two examples that send different things get different
# names, or the shared transcript quietly accumulates interactions nobody
# expects to be there.
#
# One caveat: `mode: :always` discards the transcript when the block opens, so
# a selective re-record of one example wipes what its name-sharing siblings
# recorded earlier in the same run. Harmless — they re-record too — but worth
# knowing before reaching for it.
private TEXT_CHAT      = "ollama_chat_completions_text"
private TEXT_RESPONSES = "ollama_responses_text"
private TEXT_ANTHROPIC = "ollama_anthropic_text"

private def ollama : Elelem::Server
  Elelem::Server.new("ollama", "http://localhost:11434")
end

private def client(protocol : Elelem::ProtocolKind) : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(ollama, protocol))
end

private def asked : M::Session
  session = M::Session.new("Answer in one short sentence.")
  session << M::Message.user("What is the tallest mountain on Earth?")
  session
end

describe "Ollama" do
  # One server, three protocols. The same session, the same question, three
  # wire shapes — which is the claim the shard makes, exercised against
  # something that was not written to agree with it.
  describe "a plain exchange" do
    it "completes over Chat Completions" do
      Wiretap.intercept(TEXT_CHAT) do
        reply, report = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL)

        reply.role.should eq M::Role::Assistant
        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "completes over the Responses API" do
      Wiretap.intercept(TEXT_RESPONSES) do
        reply, report = client(Elelem::ProtocolKind::Responses).send(asked, MODEL)

        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "completes over the Anthropic Messages API" do
      Wiretap.intercept(TEXT_ANTHROPIC) do
        reply, report = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL)

        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  describe "provenance" do
    # Recorded because it happened, never consulted when mapping. A session
    # that acquired a home from whoever answered would not be portable.
    it "records which deployment answered" do
      Wiretap.intercept(TEXT_CHAT) do
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL)

        provenance = reply.provenance.should_not be_nil
        provenance.model.should_not be_empty
      end
    end

    it "keeps usage out of the conversation" do
      Wiretap.intercept(TEXT_ANTHROPIC) do
        reply, _ = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL)
        key = Elelem::Protocol::Anthropic::METADATA_KEY

        reply.meta?(key, "usage").should_not be_nil
        reply.meta?(key, "stop_reason").should_not be_nil

        # Non-content facts stay in metadata. Asserting "every block is text"
        # would have been the same claim wrongly stated — it assumes a
        # non-thinking model, and breaks the moment someone changes one.
        reply.content.each do |block|
          block.should be_a(M::TextBlock | M::ReasoningBlock)
        end
        reply.content.select(M::TextBlock).should_not be_empty
      end
    end

    # Unplanned coverage: the model answering over Ollama's Anthropic endpoint
    # is a thinking model, so the trace arrives as a real `thinking` block. Up
    # to here every reasoning path was proven only against transcribed
    # fixtures.
    it "reads a thinking block from a live reply" do
      Wiretap.intercept(TEXT_ANTHROPIC) do
        reply, _ = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL)

        reasoning = reply.content.select(M::ReasoningBlock)
        next if reasoning.empty? # a non-thinking model is not a failure

        reasoning.size.should eq 1
        # Reasoning precedes the answer, as it does on the wire.
        reply.content[0].should be_a M::ReasoningBlock
      end
    end
  end

  # All three of Ollama's endpoints return reasoning, in three spellings. These
  # exist because the offline fixtures could not have found the divergence:
  # they were written from the same assumption as the readers, so they agreed
  # with them. Only a recording disagrees.
  describe "reasoning" do
    it "reads the bare `reasoning` field from Chat Completions" do
      Wiretap.intercept(TEXT_CHAT) do
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL)

        # Ollama spells this `reasoning`; vLLM and DeepSeek spell it
        # `reasoning_content`. Reading only the latter dropped the trace here
        # silently — no error, no annotation, just a missing block.
        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end

    it "reads a thinking block from the Anthropic endpoint" do
      Wiretap.intercept(TEXT_ANTHROPIC) do
        reply, _ = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL)

        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end

    it "reads a reasoning item, with its opaque payload, from the Responses API" do
      Wiretap.intercept(TEXT_RESPONSES) do
        reply, _ = client(Elelem::ProtocolKind::Responses).send(asked, MODEL)
        key = Elelem::Protocol::Responses::METADATA_KEY

        blocks = reply.content.select(M::ReasoningBlock)
        blocks.should_not be_empty
        # Ollama does send `encrypted_content` here. It is namespaced under
        # `ollama`, not `openai`, because this deployment is not that vendor —
        # so it will never be replayed to OpenAI, which could not read it.
        blocks[0].meta?(key, "encrypted_content").should_not be_nil
      end
    end
  end

  # The milestone. A question answered by one protocol, continued on another,
  # against a real server — the thing every offline spec so far has only
  # rehearsed.
  describe "the handoff" do
    it "answers on Chat Completions and continues on Anthropic" do
      Wiretap.intercept("ollama_handoff_chat_to_anthropic") do
        session = asked

        first, _ = client(Elelem::ProtocolKind::ChatCompletions).send(session, MODEL)
        session << first
        session << M::Message.user("And the deepest ocean?")

        second, report = client(Elelem::ProtocolKind::Anthropic).send(session, MODEL)
        session << second

        # Four turns, two protocols, one session that was never in either's
        # shape.
        session.messages.size.should eq 4
        second.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "answers on Anthropic and continues on the Responses API" do
      Wiretap.intercept("ollama_handoff_anthropic_to_responses") do
        session = asked

        first, _ = client(Elelem::ProtocolKind::Anthropic).send(session, MODEL)
        session << first
        session << M::Message.user("And the deepest ocean?")

        second, report = client(Elelem::ProtocolKind::Responses).send(session, MODEL)

        second.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    # Round the houses. If portability means anything, a session that has been
    # answered by all three should still be acceptable to all three.
    it "passes one session through all three protocols" do
      Wiretap.intercept("ollama_handoff_all_three") do
        session = asked

        chat, _ = client(Elelem::ProtocolKind::ChatCompletions).send(session, MODEL)
        session << chat
        session << M::Message.user("And the deepest ocean?")

        responses, _ = client(Elelem::ProtocolKind::Responses).send(session, MODEL)
        session << responses
        session << M::Message.user("And the longest river?")

        anthropic, report = client(Elelem::ProtocolKind::Anthropic).send(session, MODEL)
        session << anthropic

        session.messages.size.should eq 6
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  describe "failures" do
    # Recorded like everything else. A real 404 carries Ollama's own error body,
    # which is what the adapter's decoder has to cope with — a hand-written one
    # would only test my guess at the shape.
    it "reports an unknown model as such" do
      Wiretap.intercept("ollama_model_not_found") do
        expect_raises(Elelem::ModelNotFoundError) do
          client(Elelem::ProtocolKind::ChatCompletions).send(asked, "no-such-model")
        end
      end
    end
  end
end
