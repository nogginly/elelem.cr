require "../../spec_helper"
require "../../support/cli_output"
require "file_utils"
require "../../../src/elelem_cli/sessions"
require "../../../src/elelem_cli/commands/list"
require "../../../src/elelem_cli/commands/show"

# `list` and `show` are the two verbs that touch no network at all — they
# read what `start`/`continue` already wrote. So unlike every other spec
# under `spec/elelem_cli/commands/`, there is no Wiretap here and nothing to
# record: sessions are written directly through `Sessions.snapshot`, which
# is the same call the live commands make.
#
# Sandboxed with `$ELELEM_HOME` rather than `Dir.cd`, for the reason
# `start_spec.cr` records at length.
private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "elelem-cli-inspect-spec-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(File.join(tmp, ".elelem"))

  original_home = ENV["ELELEM_HOME"]?
  ENV["ELELEM_HOME"] = File.join(tmp, ".elelem")
  begin
    yield
  ensure
    original_home ? (ENV["ELELEM_HOME"] = original_home) : ENV.delete("ELELEM_HOME")
    FileUtils.rm_rf(tmp)
  end
end

private def seed(id : String, deployment : String, prompt : String) : Nil
  session = M::Session.new("be terse")
  session << M::Message.user(prompt)
  session << M::Message.assistant("a reply")
  Elelem::Cli::Sessions.snapshot(id, session, deployment)
end

describe Elelem::Cli::Commands::List do
  it "says so plainly when there is nothing to list" do
    with_sandbox do
      _, warned = captured { Elelem::Cli::Commands::List.run([] of String) }
      warned.should contain("No sessions yet")
    end
  end

  it "lists each session with its turn count and last deployment" do
    with_sandbox do
      seed("brisk-comet", "ollama", "what is the tallest mountain?")

      printed, _ = captured { Elelem::Cli::Commands::List.run([] of String) }

      printed.should contain("brisk-comet")
      printed.should contain("ollama")
      # One exchange is one turn, not two messages. `list` printed
      # `messages.size` until someone compared it with `show --snapshots`, and
      # this expectation is what agreed with the bug.
      printed.should contain("1 turns")
      printed.should contain("what is the tallest mountain?")
    end
  end

  # Tool results are user-role messages but are not user input, so a
  # call-and-result exchange belongs to the turn that prompted it. Counting
  # roles instead would report three turns here.
  it "counts a tool exchange as part of the turn that prompted it" do
    with_sandbox do
      session = M::Session.new
      session << M::Message.user("what is the weather?")
      session << M::Message.new(M::Role::Assistant, [
        M::ToolCallBlock.new("call-1", "weather").as(M::Block),
      ])
      session << M::Message.new(M::Role::User, [
        M::ToolResultBlock.new("call-1", [M::TextBlock.new("cold").as(M::Block)]).as(M::Block),
      ])
      session << M::Message.assistant("Cold.")
      Elelem::Cli::Sessions.snapshot("brisk-comet", session, "ollama")

      printed, _ = captured { Elelem::Cli::Commands::List.run([] of String) }

      printed.should contain("1 turns")
    end
  end

  # The ordering that matters: the thing you were just doing is the thing you
  # are most likely to want next.
  it "puts the most recently active session first" do
    with_sandbox do
      seed("quiet-otter", "ollama", "older")
      sleep 5.milliseconds
      seed("bold-falcon", "anthropic", "newer")

      printed, _ = captured { Elelem::Cli::Commands::List.run([] of String) }

      printed.index("bold-falcon").not_nil!.should be < printed.index("quiet-otter").not_nil!
    end
  end

  # A folder with no snapshots is what a crashed `start` leaves behind.
  it "skips a session folder with no saved turns rather than failing" do
    with_sandbox do
      seed("brisk-comet", "ollama", "intact")
      Dir.mkdir_p(Elelem::Cli::Sessions.path_for("empty-husk"))

      printed, _ = captured { Elelem::Cli::Commands::List.run([] of String) }

      printed.should contain("brisk-comet")
      printed.should_not contain("empty-husk")
    end
  end

  # And this is what the filesystem leaves. Found the hard way on macOS, where
  # a single .DS_Store in the sessions folder took the whole listing down.
  it "skips entries that are not session ids at all" do
    with_sandbox do
      seed("brisk-comet", "ollama", "intact")
      File.write(File.join(Elelem::Cli::Sessions.folder, ".DS_Store"), "junk")
      Dir.mkdir_p(File.join(Elelem::Cli::Sessions.folder, ".hidden-thing"))

      printed, _ = captured { Elelem::Cli::Commands::List.run([] of String) }

      printed.should contain("brisk-comet")
      printed.should_not contain("DS_Store")
      printed.should_not contain("hidden-thing")
    end
  end
end

describe Elelem::Cli::Commands::Show do
  it "prints the system prompt and every turn" do
    with_sandbox do
      seed("brisk-comet", "ollama", "what is the tallest mountain?")

      printed, _ = captured { Elelem::Cli::Commands::Show.run(["brisk-comet"]) }

      printed.should contain("system: be terse")
      printed.should contain("user:")
      printed.should contain("assistant:")
      printed.should contain("a reply")
    end
  end

  # The whole reason `Output.describe` exists rather than `Message#text`. A
  # transcript that silently omitted these would misrepresent exactly the
  # sessions this shard exists to carry between providers.
  it "renders blocks that are not text, rather than dropping them" do
    with_sandbox do
      session = M::Session.new
      session << M::Message.user("weather?")
      session << M::Message.new(M::Role::Assistant, [
        M::ReasoningBlock.new("thinking about it").as(M::Block),
        M::ToolCallBlock.new("c1", "get_weather",
          M::Object{"city" => "Paris".as(M::Value)}).as(M::Block),
      ])
      Elelem::Cli::Sessions.snapshot("brisk-comet", session, "gemini")

      printed, _ = captured { Elelem::Cli::Commands::Show.run(["brisk-comet"]) }

      printed.should contain("[reasoning] thinking about it")
      printed.should contain("[tool call get_weather")
      printed.should contain("Paris")
    end
  end

  it "lists the append-only turn history under --snapshots" do
    with_sandbox do
      seed("brisk-comet", "ollama", "first")
      sleep 5.milliseconds
      seed("brisk-comet", "anthropic", "second")

      printed, _ = captured { Elelem::Cli::Commands::Show.run(["brisk-comet", "--snapshots"]) }

      printed.lines.size.should eq 2
      printed.should contain("ollama")
      printed.should contain("anthropic")
    end
  end

  # `--json` hands over the stored bytes, not a re-serialization, so this is
  # a byte comparison rather than a semantic one on purpose.
  it "emits the archive exactly as stored under --json" do
    with_sandbox do
      seed("brisk-comet", "ollama", "hello")

      printed, _ = captured { Elelem::Cli::Commands::Show.run(["brisk-comet", "--json"]) }

      printed.chomp.should eq(Elelem::Cli::Sessions.latest_archive("brisk-comet"))
      M::Archive.read(printed).messages.size.should eq 2
    end
  end

  it "refuses two flags that ask for different things" do
    with_sandbox do
      seed("brisk-comet", "ollama", "hello")
      expect_raises(ArgumentError, /different things/) do
        Elelem::Cli::Commands::Show.run(["brisk-comet", "--snapshots", "--json"])
      end
    end
  end

  it "names the session it could not find" do
    with_sandbox do
      expect_raises(Elelem::Cli::SessionError, /no-such-session/) do
        Elelem::Cli::Commands::Show.run(["no-such-session"])
      end
    end
  end
end
