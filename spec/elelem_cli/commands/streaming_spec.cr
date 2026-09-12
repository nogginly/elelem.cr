require "../../spec_helper"
require "../../support/cli_output"
require "file_utils"
require "../../../src/elelem_cli/config"
require "../../../src/elelem_cli/sessions"
require "../../../src/elelem_cli/commands/start"
require "../../../src/elelem_cli/commands/continue"

# The CLI's own streamed turn, end to end: flag, `Display`, `Query#stream`,
# `Output`, and the file that lands on disk.
#
# **Why this is recorded against Ollama rather than a vendor.** Everything
# under test here is protocol-agnostic — that the reply is printed once rather
# than twice, that stdout carries reply text and nothing else, that the session
# saved by a streamed run is the one a non-streamed run would have saved.
# `spec/live/*_streaming_spec.cr` already proves the four assemblers against
# the endpoints that validate. Paying a vendor to re-prove the plumbing above
# them would buy a transcript, not an answer.
#
# **Why `--stream` and not `defaults.streaming`.** `Output.stream` is an
# `IO::Memory` throughout a spec run, so the tty floor declines to stream and
# configuration does not lift it. The flag goes through the floor, which is
# what `docs/CLI_DESIGN.md` says it is for and the only way either mode can be
# recorded here. The floor itself is asserted below, and is free: a run that
# declines to stream sends the body a non-streamed run sends.
#
# **What *stdout is the saved reply* is really for.** `Output.reply` prints
# `Message#text`, repair removes only tool calls, so a streamed run's stdout
# and its saved session agree exactly today. That agreement is a commitment
# rather than a coincidence — see *Printed bytes precede repair* — and it has
# never been asserted anywhere. Pinning it means the first change that puts
# something other than reply text on stdout goes red here, rather than being
# discovered in someone's scrollback a week later.
private MODEL = "gemma4:26b-mxfp8"

private PROMPT = "What is the tallest mountain on Earth?"
private SYSTEM = "Answer in one short sentence."

private STREAM_START    = "elelem_cli_stream_start"
private STREAM_CONTINUE = "elelem_cli_stream_continue"

# `defaults.streaming: true` is deliberate. Every example that streams passes
# the flag anyway; the one example that passes no flag is asserting that this
# key cannot lift the tty floor on its own.
#
# See `start_spec.cr`'s `with_sandbox` for why this is `$ELELEM_CONFIG` /
# `$ELELEM_HOME` rather than `Dir.cd`.
private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "elelem-cli-streaming-spec-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(File.join(tmp, ".elelem"))
  config_path = File.join(tmp, "elelem.yaml")
  File.write(config_path, <<-YAML)
    servers:
      ollama:
        protocol: chat_completions
        url: http://localhost:11434
    deployments:
      ollama:
        server: ollama
        model: #{MODEL}
    defaults:
      streaming: true
    YAML

  original_home = ENV["ELELEM_HOME"]?
  original_config = ENV["ELELEM_CONFIG"]?
  ENV["ELELEM_HOME"] = File.join(tmp, ".elelem")
  ENV["ELELEM_CONFIG"] = config_path
  begin
    captured { yield }
  ensure
    original_home ? (ENV["ELELEM_HOME"] = original_home) : ENV.delete("ELELEM_HOME")
    original_config ? (ENV["ELELEM_CONFIG"] = original_config) : ENV.delete("ELELEM_CONFIG")
    FileUtils.rm_rf(tmp)
  end
end

# What the CLI has printed so far in this example.
#
# Read inside the sandbox rather than from `captured`'s return value, because
# every assertion here compares stdout against the saved session and the
# sandbox deletes that session on the way out.
private def printed : String
  Elelem::Cli::Output.stream.to_s
end

private def warned : String
  Elelem::Cli::Output.error_stream.to_s
end

private def only_session : String
  Dir.children(Elelem::Cli::Sessions.folder).first
end

private def saved_reply(id : String) : M::Message
  Elelem::Cli::Sessions.latest(id).messages.last
end

describe "the CLI's streamed turn" do
  describe "elelem start --stream" do
    it "saves the session a non-streamed run would have saved" do
      # A streamed reply is the same `MPSH::Message` as an unstreamed one by
      # construction — frames become the protocol's own `Wire::Response` and
      # take the existing `export_reply`. This is that claim arriving where a
      # user can check it: the file on disk.
      with_sandbox do
        Wiretap.intercept(STREAM_START) do
          Elelem::Cli::Commands::Start.run(["ollama", PROMPT, SYSTEM, "--stream"])
        end

        session = Elelem::Cli::Sessions.latest(only_session)
        session.messages.size.should eq(2)
        session.messages.first.role.should eq(M::Role::User)
        session.messages.last.role.should eq(M::Role::Assistant)
        session.messages.last.content.select(M::TextBlock).should_not be_empty
        session.messages.last.ending.should eq(M::Ending::Complete)
      end
    end

    it "prints the reply once, not twice" do
      # `Output.reply(reply) unless report.streamed?`, read off the report
      # rather than off the request. Both halves are regressions: suppressing
      # on the request prints nothing at all on a protocol that fell back to
      # one body, and not suppressing at all prints the whole answer a second
      # time under the first.
      with_sandbox do
        Wiretap.intercept(STREAM_START) do
          Elelem::Cli::Commands::Start.run(["ollama", PROMPT, SYSTEM, "--stream"])
        end

        text = saved_reply(only_session).text
        text.should_not be_empty
        printed.scan(text).size.should eq(1)
      end
    end

    it "puts the reply on stdout and nothing else" do
      # Streamed stdout is the text blocks of the saved message plus the
      # closing newline `Output.end_stream` writes — no reasoning, no session
      # id, no warning, and nothing narrated that the archive does not hold.
      with_sandbox do
        Wiretap.intercept(STREAM_START) do
          Elelem::Cli::Commands::Start.run(["ollama", PROMPT, SYSTEM, "--stream"])
        end

        printed.should eq("#{saved_reply(only_session).text}\n")
        warned.should contain("Session: ")
        printed.should_not contain("Session: ")
      end
    end

    it "streams no reasoning unless asked" do
      # Reasoning goes to stderr and only behind the flag, so the default
      # streamed run leaves the thinking rule off both streams entirely. The
      # model on this deployment may or may not reason; what is asserted is
      # what the CLI does with it either way.
      with_sandbox do
        Wiretap.intercept(STREAM_START) do
          Elelem::Cli::Commands::Start.run(["ollama", PROMPT, SYSTEM, "--stream"])
        end

        printed.should_not contain("thinking")
        warned.should_not contain("┄┄┄ thinking ┄┄┄")
      end
    end
  end

  describe "elelem continue --stream" do
    it "appends a streamed turn to a session that already exists" do
      with_sandbox do
        Wiretap.intercept(STREAM_START) do
          Elelem::Cli::Commands::Start.run(["ollama", PROMPT, SYSTEM, "--stream"])
        end
        id = only_session

        Wiretap.intercept(STREAM_CONTINUE) do
          Elelem::Cli::Commands::Continue.run([id, "And the second tallest?", "--stream"])
        end

        session = Elelem::Cli::Sessions.latest(id)
        session.messages.size.should eq(4)
        session.messages.last.role.should eq(M::Role::Assistant)
        session.messages.last.content.select(M::TextBlock).should_not be_empty
      end
    end

    it "prints only the second answer, not the conversation it continued" do
      # A continued session holds four messages and stdout holds one of them.
      # The regression this names is a streamed `continue` that replays the
      # whole transcript to stdout because it printed from the session rather
      # than from the turn.
      with_sandbox do
        Wiretap.intercept(STREAM_START) do
          Elelem::Cli::Commands::Start.run(["ollama", PROMPT, SYSTEM, "--stream"])
        end
        id = only_session
        first = saved_reply(id).text

        Elelem::Cli::Output.stream.as(IO::Memory).clear

        Wiretap.intercept(STREAM_CONTINUE) do
          Elelem::Cli::Commands::Continue.run([id, "And the second tallest?", "--stream"])
        end

        printed.should eq("#{saved_reply(id).text}\n")
        printed.should_not contain(first)
      end
    end
  end

  describe "the tty floor" do
    it "declines to stream into a redirected stdout, whatever the config says" do
      # `defaults.streaming: true` is set in the sandbox above and does not
      # lift the floor, because a spec run's `Output.stream` is an
      # `IO::Memory`. The request this sends is therefore the one a
      # non-streamed run sends, which is why it replays from `start_spec.cr`'s
      # transcript rather than needing one of its own — and why this example
      # costs nothing to keep.
      #
      # The reply still reaches stdout, by the other path: `report.streamed?`
      # is false, so `Output.reply` prints it.
      with_sandbox do
        Wiretap.intercept("elelem_cli_start_ollama") do
          Elelem::Cli::Commands::Start.run(["ollama", PROMPT, SYSTEM])
        end

        printed.should eq("#{saved_reply(only_session).text}\n")
      end
    end
  end
end
