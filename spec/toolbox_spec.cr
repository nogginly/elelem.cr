require "./spec_helper"

# `Toolbox` touches no wire, so this needs no transcript. What it does touch is
# the invariant every other part of this shard is arranged around: a session
# holding a tool call must also hold that call's result. Most of the file is
# that one property, approached from each way it can be broken.
private class Weather
  include Elelem::Function

  def name : String
    "get_weather"
  end

  def description : String?
    "Look up the current weather in a city"
  end

  def parameters : String
    %({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]})
  end

  def call(arguments : M::Object) : Array(M::Block)
    city = arguments["city"]?.as?(String) || "somewhere"
    [M::TextBlock.new("18C, light rain in #{city}").as(M::Block)]
  end
end

private class Chart
  include Elelem::Function

  def name : String
    "draw_chart"
  end

  def description : String?
    "Draw a chart"
  end

  def parameters : String
    %({"type":"object","properties":{}})
  end

  def call(arguments : M::Object) : Array(M::Block)
    [
      M::TextBlock.new("here is the chart").as(M::Block),
      M::ImageBlock.new(M::InlinePayload.new("aGVsbG8=", "image/png", 5_i64)).as(M::Block),
    ]
  end
end

private class Broken
  include Elelem::Function

  def name : String
    "report_failure"
  end

  def description : String?
    "Always fails in the sanctioned way"
  end

  def parameters : String
    %({"type":"object","properties":{}})
  end

  def call(arguments : M::Object) : Array(M::Block)
    raise Elelem::Function::Failure.new("the upstream service is down")
  end
end

private class Exploding
  include Elelem::Function

  def name : String
    "raise_anything"
  end

  def description : String?
    "Fails in a way nobody planned for"
  end

  def parameters : String
    %({"type":"object","properties":{}})
  end

  def call(arguments : M::Object) : Array(M::Block)
    raise KeyError.new("no such key: region")
  end
end

private def toolbox : Elelem::Toolbox
  Elelem::Toolbox.new([Weather.new, Chart.new, Broken.new, Exploding.new] of Elelem::Function)
end

private def calling(*names : String, server_executed : Bool = false) : M::Message
  blocks = names.map_with_index do |name, index|
    M::ToolCallBlock.new("call_#{index}", name,
      M::Object{"city" => "Paris".as(M::Value)},
      server_executed: server_executed).as(M::Block)
  end
  M::Message.new(M::Role::Assistant, blocks.to_a)
end

private def conversation(reply : M::Message) : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris?")
  session << reply
  session
end

describe Elelem::Toolbox do
  describe "#tools" do
    it "declares every function it holds, in order" do
      declared = toolbox.tools
      declared.map(&.name).should eq ["get_weather", "draw_chart", "report_failure", "raise_anything"]
      declared.first.description.should eq "Look up the current weather in a city"
      declared.first.parameters.should contain "city"
    end
  end

  describe ".new" do
    it "refuses two functions answering to one name" do
      # A call names a tool. Preferring either silently is worse than declining
      # to start, and the ambiguity is visible at construction rather than at
      # the moment a model happens to call the contested name.
      expect_raises(ArgumentError, /duplicate tool name/) do
        Elelem::Toolbox.new([Weather.new, Weather.new] of Elelem::Function)
      end
    end
  end

  describe "#dispatch" do
    it "returns one user-role message of results, paired by call id" do
      results = toolbox.dispatch(calling("get_weather")).should_not be_nil

      results.role.should eq M::Role::User
      blocks = results.content.select(M::ToolResultBlock)
      blocks.size.should eq 1
      blocks.first.call_id.should eq "call_0"
      blocks.first.is_error?.should be_false
      blocks.first.content.select(M::TextBlock).first.text.should contain "Paris"
    end

    it "carries a tool that returns an image, without a second content type" do
      # The reason `ToolResultBlock#content` is a block list rather than a
      # string: a chart comes back as blocks the four mappers already know how
      # to carry, and nothing in between has to learn a tool-specific shape.
      results = toolbox.dispatch(calling("draw_chart")).should_not be_nil

      content = results.content.select(M::ToolResultBlock).first.content
      content.select(M::TextBlock).should_not be_empty
      content.select(M::ImageBlock).first.media_type.should eq "image/png"
    end

    it "runs several calls in the order they arrived" do
      results = toolbox.dispatch(calling("get_weather", "draw_chart")).should_not be_nil

      results.content.select(M::ToolResultBlock).map(&.call_id).should eq ["call_0", "call_1"]
    end

    it "returns nil when the reply holds no calls" do
      toolbox.dispatch(M::Message.assistant("Mount Everest.")).should be_nil
    end

    it "skips calls the provider already ran" do
      # A server-executed call arrives with its result attached. Running it
      # again would be a second, unasked-for execution of somebody's side
      # effect.
      toolbox.dispatch(calling("get_weather", server_executed: true)).should be_nil
    end
  end

  describe "#dispatch when something goes wrong" do
    it "reports a Failure to the model and not to the archive" do
      # `is_error` is what a mapper carries; `exception` is written by `Archive`
      # and read back, and nowhere else. A tool that ran and could not do the
      # job did not blow up, so only the first is true of it.
      results = toolbox.dispatch(calling("report_failure")).should_not be_nil
      block = results.content.select(M::ToolResultBlock).first

      block.is_error?.should be_true
      block.exception.should be_nil
      block.content.select(M::TextBlock).first.text.should contain "upstream service is down"
    end

    it "reports an unplanned raise to both" do
      # The asymmetry above, from the other side. `exception` records that
      # dispatch blew up rather than reported — but since no mapper puts it on
      # the wire, `is_error` has to be set too or the model is never told the
      # tool failed at all.
      results = toolbox.dispatch(calling("raise_anything")).should_not be_nil
      block = results.content.select(M::ToolResultBlock).first

      block.is_error?.should be_true
      block.exception.should_not be_nil
      block.exception.not_nil!.should contain "KeyError"
    end

    it "answers a call naming a tool it does not hold" do
      results = toolbox.dispatch(calling("get_weather", "summon_kraken")).should_not be_nil
      blocks = results.content.select(M::ToolResultBlock)

      blocks.size.should eq 2
      blocks.last.is_error?.should be_true
      blocks.last.content.select(M::TextBlock).first.text.should contain "summon_kraken"
    end

    it "leaves a sendable session however the tools behaved" do
      # The property the three examples above exist to protect. Every route
      # through `#run` produces a result, so no route leaves a dangling call —
      # which is the one shape `MPSH::Repair` says a session must never reach.
      reply = calling("get_weather", "report_failure", "raise_anything", "summon_kraken")
      session = conversation(reply)
      session << toolbox.dispatch(reply).should_not be_nil

      M::Repair.sendable?(session).should be_true
    end
  end

  describe "#dispatch on an interrupted turn" do
    it "runs nothing, because repair has already dropped the call" do
      # The rule in `docs/CLI_DESIGN.md`'s *The durable announcement lands after
      # repair, not after `finish`*, enforced here so that a caller who has not
      # read it cannot get it wrong. Dispatching a call that repair removed
      # would append a result whose call is missing from the session — the same
      # invariant broken from the other direction.
      cut = calling("get_weather")
      cut.ending = M::Ending::Interrupted

      M::Repair.needed?(cut).should be_true
      toolbox.dispatch(cut).should be_nil
    end

    it "is unchanged by having been repaired already" do
      # `#dispatch` repairs its argument rather than trusting it, so a caller
      # that passes the message it appended and a caller that passes the raw
      # reply get the same answer. Repair is idempotent; this says so.
      #
      # The reply needs text as well as a call, or there is nothing to be
      # idempotent about: repair returns `nil` for a message whose only content
      # was the call it removed, which the example above covers instead.
      cut = calling("get_weather")
      cut.content.unshift(M::TextBlock.new("Let me look that up.").as(M::Block))
      cut.ending = M::Ending::Interrupted

      repaired = M::Repair.repaired(cut).should_not be_nil
      repaired.content.select(M::ToolCallBlock).should be_empty
      repaired.text.should contain "look that up"

      toolbox.dispatch(repaired).should be_nil
    end

    it "drops a reply that was nothing but an interrupted call" do
      # Repair has nothing left to return, so there is no message to append and
      # nothing to dispatch. Both facts are the same fact, and `#dispatch`
      # reports it as the same `nil` a reply with no calls at all produces.
      cut = calling("get_weather")
      cut.ending = M::Ending::Interrupted

      M::Repair.repaired(cut).should be_nil
      toolbox.dispatch(cut).should be_nil
    end

    it "still runs a complete turn's calls" do
      # The other half of the rule: repair drops calls on a *cut* turn only, and
      # a turn that ended normally holding a call is exactly the turn a toolbox
      # exists for.
      reply = calling("get_weather")
      reply.ending.should eq M::Ending::Complete

      toolbox.dispatch(reply).should_not be_nil
    end
  end
end
