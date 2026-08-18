require "../spec_helper"
require "../fixtures/mpsh_fixtures"

# Pass A: construction only.
#
# No mapper exists yet, so there is nothing to round-trip. The job here is
# narrow and worth stating plainly: put every fixture through the type checker
# and confirm each holds what was put into it. Crystal only checks code paths it
# instantiates, so until this file existed essentially none of `mpsh/` had been
# compiled.
#
# The single riskiest construct is `ToolResultBlock#content : Array(Block)`,
# which forward-references the recursive union alias that includes
# `ToolResultBlock` itself. If that does not resolve, it fails here.
module Elelem
  alias M = Elelem::MPSH

  describe "MPSH construction" do
    it "builds every fixture" do
      Fixtures.all.each do |name, session|
        session.should be_a(M::Session)
        session.messages.each do |message|
          message.content.should be_a(Array(M::Block))
        end
        name.should_not be_empty
      end
    end

    it "exhaustively matches the block union" do
      # The compiler enforces this: adding a block kind without a branch here
      # is a compile error, which is the entire reason `Block` is a union
      # rather than a class hierarchy.
      kinds = Fixtures.all.values.flat_map(&.messages).flat_map(&.content).map do |block|
        case block
        in M::TextBlock       then M::BlockKind::Text
        in M::ImageBlock      then M::BlockKind::Image
        in M::AudioBlock      then M::BlockKind::Audio
        in M::DocumentBlock   then M::BlockKind::Document
        in M::ToolCallBlock   then M::BlockKind::ToolCall
        in M::ToolResultBlock then M::BlockKind::ToolResult
        in M::ReasoningBlock  then M::BlockKind::Reasoning
        in M::RefusalBlock    then M::BlockKind::Refusal
        end
      end

      # Every kind in the catalog appears somewhere in the fixture set. A new
      # block kind with no fixture fails here rather than going untested.
      kinds.to_set.should eq(M::BlockKind.values.to_set)
    end

    describe "nested tool results" do
      it "holds an interleaved block list" do
        session = Fixtures.tool_call_image_result
        result = session.messages[2].content.first.as(M::ToolResultBlock)

        result.content.size.should eq(2)
        result.content[0].should be_a(M::TextBlock)
        result.content[1].should be_a(M::ImageBlock)
        result.text_only?.should be_false
      end

      it "recognises a text-only result" do
        session = Fixtures.tool_call_text_result
        result = session.messages[2].content.first.as(M::ToolResultBlock)
        result.text_only?.should be_true
      end

      it "keeps exception distinct from is_error" do
        session = Fixtures.tool_result_error
        result = session.messages[2].content.first.as(M::ToolResultBlock)
        result.is_error?.should be_true
        result.exception.should eq("Net::TimeoutError")
      end
    end

    describe "payloads" do
      it "stores raw base64 with a separate media type, never a data URI" do
        session = Fixtures.text_and_image
        image = session.messages[0].content[1].as(M::ImageBlock)
        payload = image.payload.as(M::InlinePayload)

        payload.base64.should_not contain("data:")
        payload.base64.should_not contain(";base64,")
        payload.media_type.should eq("image/png")
      end

      it "supports a reference form" do
        session = Fixtures.reference_payload
        document = session.messages[0].content[1].as(M::DocumentBlock)
        document.payload.inline?.should be_false
        document.payload.byte_size.should eq(4_096)
      end
    end

    describe "text_fallback" do
      it "separates degradable audio from refusable audio" do
        Fixtures.audio_with_transcript
          .messages[0].content[1].as(M::AudioBlock).text_fallback.should_not be_nil
        Fixtures.audio_without_transcript
          .messages[0].content[1].as(M::AudioBlock).text_fallback.should be_nil
      end
    end

    describe "provider metadata" do
      it "namespaces by provider on both blocks and messages" do
        message = Fixtures.foreign_provider_metadata.messages[1]
        message.meta?("anthropic", "stop_reason").should eq("end_turn")
        message.meta_for("openai").should be_nil

        block = message.content.first.as(M::TextBlock)
        block.meta?("anthropic", "cache_control").should eq("ephemeral")
        block.meta_for("gemini").should be_nil
      end

      it "carries an opaque reasoning payload without exposing it canonically" do
        block = Fixtures.reasoning_with_provider_payload
          .messages[1].content.first.as(M::ReasoningBlock)

        block.redacted?.should be_true
        block.text.should be_nil
        block.meta?("openai", "encrypted_content").should eq("b3BhcXVl")
      end
    end

    describe "server-executed tools" do
      it "flags both the call and its result" do
        session = Fixtures.server_executed_tool
        session.messages[1].content.first.as(M::ToolCallBlock).server_executed?.should be_true
        session.messages[2].content.first.as(M::ToolResultBlock).server_executed?.should be_true
      end

      it "leaves client-executed tools unflagged" do
        session = Fixtures.tool_call_text_result
        session.messages[1].content.first.as(M::ToolCallBlock).server_executed?.should be_false
      end
    end

    describe "tool call arguments" do
      it "stores them structured rather than as a JSON string" do
        call = Fixtures.tool_call_text_result.messages[1].content.first.as(M::ToolCallBlock)
        call.arguments.should be_a(M::Object)
        call.arguments["city"].should eq("Kyoto")
      end
    end

    describe "refusal" do
      it "distinguishes a refusal with a reason from one without" do
        Fixtures.refusal_with_reason
          .messages[1].content.first.as(M::RefusalBlock).reason.should_not be_nil
        Fixtures.refusal_without_reason
          .messages[1].content.first.as(M::RefusalBlock).reason.should be_nil
      end
    end
  end

  describe "turn segmentation" do
    it "treats a tool result as continuation, not a new turn" do
      turns = M::Turns.segment(Fixtures.tool_call_text_result.messages)
      turns.size.should eq(1)
      turns.first.size.should eq(4)
      turns.first.completed?.should be_false
    end

    it "opens a turn at each genuine user input" do
      turns = M::Turns.segment(Fixtures.reasoning_across_turns.messages)
      turns.size.should eq(3)
      turns[0].completed?.should be_true
      turns[1].completed?.should be_true
      turns[2].completed?.should be_false
    end

    it "never marks the open turn as completed" do
      completed = M::Turns.completed_indices(Fixtures.reasoning_mid_tool_call.messages)
      completed.should be_empty
    end

    it "handles history that opens with an assistant message" do
      turns = M::Turns.segment(Fixtures.assistant_first.messages)
      turns.first.first.should eq(0)
    end

    it "returns no turns for an empty history" do
      M::Turns.segment([] of M::Message).should be_empty
    end
  end
end
