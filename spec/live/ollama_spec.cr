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

private REASONING_OFF_CHAT       = "ollama_reasoning_off_chat_completions"
private REASONING_OFF_ANTHROPIC  = "ollama_reasoning_off_anthropic"
private REASONING_RUNG_ANTHROPIC = "ollama_reasoning_rung_anthropic"

private def ollama : Elelem::Server
  Elelem::Server.new("ollama", "http://localhost:11434")
end

private def client(protocol : Elelem::ProtocolKind,
                   policy : Elelem::Capability::Policy = Elelem::Capability::Policy::Compensating) : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(ollama, protocol), policy)
end

private def asked : M::Session
  session = M::Session.new("Answer in one short sentence.")
  session << M::Message.user("What is the tallest mountain on Earth?")
  session
end

# Every live request carries a cap.
#
# Not tidiness: an uncapped local model already cost this suite a twelve-minute
# stall and a 4,096-token turn that never reached an answer. A cap makes the
# run bounded, re-recording cheap, and the reasoning of a verbose model
# somebody else's problem.
private CAP = Elelem::Options.new(max_output_tokens: 512)

# Deliberately far too small to finish a sentence. Reproduces an interrupted
# turn on demand, where previously we waited for a model to over-think.
private TINY = Elelem::Options.new(max_output_tokens: 24)

private def weather_tool : Elelem::Tool
  Elelem::Tool.new("get_weather", "Look up the current weather in a city",
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}))
end

private def armed : Elelem::Options
  Elelem::Options.new(tools: [weather_tool], max_output_tokens: 512)
end

private def tool_question : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")
  session
end

describe "Ollama" do
  # One server, three protocols. The same session, the same question, three
  # wire shapes — which is the claim the shard makes, exercised against
  # something that was not written to agree with it.
  describe "a plain exchange" do
    it "completes over Chat Completions" do
      Wiretap.intercept(TEXT_CHAT) do
        reply, report = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL, options: CAP)

        reply.role.should eq M::Role::Assistant
        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "completes over the Responses API" do
      Wiretap.intercept(TEXT_RESPONSES) do
        reply, report = client(Elelem::ProtocolKind::Responses).send(asked, MODEL, options: CAP)

        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "completes over the Anthropic Messages API" do
      Wiretap.intercept(TEXT_ANTHROPIC) do
        reply, report = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL, options: CAP)

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
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL, options: CAP)

        provenance = reply.provenance.should_not be_nil
        provenance.model.should_not be_empty
      end
    end

    it "keeps usage out of the conversation" do
      Wiretap.intercept(TEXT_ANTHROPIC) do
        reply, _ = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL, options: CAP)
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
        reply, _ = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL, options: CAP)

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
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL, options: CAP)

        # Ollama spells this `reasoning`; vLLM and DeepSeek spell it
        # `reasoning_content`. Reading only the latter dropped the trace here
        # silently — no error, no annotation, just a missing block.
        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end

    it "reads a thinking block from the Anthropic endpoint" do
      Wiretap.intercept(TEXT_ANTHROPIC) do
        reply, _ = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL, options: CAP)

        reply.content.select(M::ReasoningBlock).should_not be_empty
      end
    end

    it "reads a reasoning item, with its opaque payload, from the Responses API" do
      Wiretap.intercept(TEXT_RESPONSES) do
        reply, _ = client(Elelem::ProtocolKind::Responses).send(asked, MODEL, options: CAP)
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

        # Ollama's Chat Completions endpoint returns a `reasoning` trace
        # unbidden, with no metadata attaching it to anyone — and Anthropic's
        # own `thinking` block requires a signature nothing here has. Lenient,
        # deliberately: the loss is real (`Outcome::Degraded`, not `Refused`)
        # and this test is about the handoff completing, not about carrying
        # a foreign reasoning trace unscathed. See `spec/live/anthropic_spec.cr`.
        second, report = client(Elelem::ProtocolKind::Anthropic, Elelem::Capability::Policy::Lenient)
          .send(session, MODEL)
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

        # Same reason as the two-protocol handoff above: whichever leg fed
        # this session incidental reasoning with no replayable signature, the
        # Anthropic leg cannot carry it. Lenient, deliberately.
        anthropic, report = client(Elelem::ProtocolKind::Anthropic, Elelem::Capability::Policy::Lenient)
          .send(session, MODEL)
        session << anthropic

        session.messages.size.should eq 6
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  # The turn loop, end to end, against a real server.
  #
  # Until tool declarations existed, nothing could provoke a call: the mappers
  # translated calls and results faithfully in history, but a model offered no
  # tools has nothing to call. These are the first specs in the project where
  # a provider decides to invoke something and we answer it.
  #
  # They are also the first live exercise of `CallIdTable`. Every previous test
  # of pairing round-tripped through our own mappers, which agree with
  # themselves by construction; here the identifier is one Ollama minted.
  describe "tool calls" do
    it "calls a declared tool and accepts the result, over Chat Completions" do
      Wiretap.intercept("ollama_tools_chat_completions") do
        session = tool_question
        turn = client(Elelem::ProtocolKind::ChatCompletions)

        reply, _ = turn.send(session, MODEL, options: armed)
        session << reply

        calls = reply.content.select(M::ToolCallBlock).reject(&.server_executed?)
        calls.size.should eq 1
        calls[0].name.should eq "get_weather"
        # The model chose the argument; we assert the shape, not the value.
        calls[0].arguments.should be_a M::Object

        # Dispatch, as a caller would.
        session << M::Message.new(M::Role::User, calls.map do |call|
          M::ToolResultBlock.new(call.call_id,
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)
        end)

        answer, report = turn.send(session, MODEL, options: armed)
        answer.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "calls a declared tool and accepts the result, over Anthropic" do
      Wiretap.intercept("ollama_tools_anthropic") do
        session = tool_question
        # Ollama's Anthropic-compatible endpoint returns a `thinking` block
        # with no signature on every reply (docs/servers/OLLAMA.md) — so the
        # second call here has to replay one, and cannot. Lenient,
        # deliberately: the drop is real and recorded, not silent.
        turn = client(Elelem::ProtocolKind::Anthropic, Elelem::Capability::Policy::Lenient)

        reply, _ = turn.send(session, MODEL, options: armed)
        session << reply

        calls = reply.content.select(M::ToolCallBlock).reject(&.server_executed?)
        calls.size.should eq 1

        session << M::Message.new(M::Role::User, calls.map do |call|
          M::ToolResultBlock.new(call.call_id,
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)
        end)

        answer, _ = turn.send(session, MODEL, options: armed)
        answer.content.select(M::TextBlock).should_not be_empty
      end
    end

    # The handoff, now with a tool call in the history. A call minted by one
    # protocol has to be rendered by another — and on Gemini it would be paired
    # by name and ordering rather than by identifier, which is the case
    # `CallIdTable` exists for.
    it "carries a tool exchange from Chat Completions to Anthropic" do
      Wiretap.intercept("ollama_tools_handoff") do
        session = tool_question

        reply, _ = client(Elelem::ProtocolKind::ChatCompletions)
          .send(session, MODEL, options: armed)
        session << reply

        calls = reply.content.select(M::ToolCallBlock).reject(&.server_executed?)
        calls.size.should eq 1

        session << M::Message.new(M::Role::User, calls.map do |call|
          M::ToolResultBlock.new(call.call_id,
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)
        end)

        # Different protocol, same conversation, including the call and its
        # answer. Lenient on the Anthropic leg for the same reason as the
        # other handoffs above: the tool call and its result carry over
        # exactly (that is what this test proves), but Chat Completions'
        # incidental reasoning trace has no signature to carry over with it.
        answer, report = client(Elelem::ProtocolKind::Anthropic, Elelem::Capability::Policy::Lenient)
          .send(session, MODEL, options: armed)

        answer.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  # An interrupted turn, on purpose. The first time this appeared it was an
  # accident — a small model reasoning past its ceiling — and an accident is a
  # poor fixture.
  # Reasoning controls, against a server that was not written to agree with us.
  #
  # What these can and cannot prove is unusually lopsided, so it is worth being
  # explicit. Ollama honours `reasoning_effort: none` — the response comes back
  # with no reasoning at all — so `Off` is genuinely falsifiable here. It gives
  # no sign of honouring a *rung*: `low` produced a full reasoning trace, which
  # is indistinguishable from an unknown field being dropped. So the rung
  # examples assert that the request is *accepted*, and nothing about what the
  # model did with it. See `docs/servers/OLLAMA.md`.
  #
  # The caps are deliberately generous. Reasoning and answer share one ceiling,
  # and a request that spends the lot thinking returns empty content with
  # `finish_reason: length` — the same shape as the runaway that put `CAP` in
  # this file, one layer down.
  describe "reasoning controls" do
    it "switches thinking off over Chat Completions" do
      Wiretap.intercept(REASONING_OFF_CHAT) do
        reply, report = client(Elelem::ProtocolKind::ChatCompletions).send(
          asked, MODEL,
          options: Elelem::Options.new(max_output_tokens: 256,
            reasoning: Elelem::Reasoning::Off.new))

        # The claim: asking for no thinking produced none. Ollama translates
        # this one, so a regression here is real rather than a dropped field.
        reply.content.select(M::ReasoningBlock).should be_empty
        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    # Honoured here too, and by a different spelling: `Off` renders as
    # `thinking: {type: "disabled"}` rather than as a rung, because disabling
    # is not a point on the effort scale. Both spellings of the same request,
    # both obeyed — which is more than this server does for the rungs
    # themselves.
    it "switches thinking off over the Anthropic Messages API" do
      Wiretap.intercept(REASONING_OFF_ANTHROPIC) do
        reply, report = client(Elelem::ProtocolKind::Anthropic).send(
          asked, MODEL,
          options: Elelem::Options.new(max_output_tokens: 256,
            reasoning: Elelem::Reasoning::Off.new))

        reply.content.select(M::ReasoningBlock).should be_empty
        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    # The optimistic default meeting a real server. An unknown model narrows to
    # `Effort`, which renders `output_config` — a parameter this endpoint has
    # no reason to know. It is accepted rather than rejected, which is the only
    # thing this example claims, and the thing that would have broken every
    # Anthropic-endpoint caller who set a rung.
    # Recorded: the rung was accepted and a full thinking block came back
    # anyway, so this asserts acceptance and nothing about obedience.
    it "has its rung accepted over the Anthropic Messages API" do
      Wiretap.intercept(REASONING_RUNG_ANTHROPIC) do
        reply, report = client(Elelem::ProtocolKind::Anthropic).send(
          asked, MODEL,
          options: Elelem::Options.new(max_output_tokens: 256,
            reasoning: Elelem::Reasoning::Effort::Low))

        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  describe "truncation" do
    it "reports a turn cut short by the cap" do
      Wiretap.intercept("ollama_truncated_anthropic") do
        reply, _ = client(Elelem::ProtocolKind::Anthropic).send(asked, MODEL, options: TINY)
        key = Elelem::Protocol::Anthropic::METADATA_KEY

        # The turn is honest about being incomplete: the stop reason says so,
        # and repair is the caller's business, not the exporter's.
        reply.meta?(key, "stop_reason").should eq "max_tokens"
        reply.content.should_not be_empty
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
