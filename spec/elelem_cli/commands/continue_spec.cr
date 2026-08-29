require "../../spec_helper"
require "file_utils"
require "../../../src/elelem_cli/config"
require "../../../src/elelem_cli/sessions"
require "../../../src/elelem_cli/commands/start"
require "../../../src/elelem_cli/commands/continue"

# Two deployments, same server, same model, different protocol — the
# cross-protocol handoff `elelem` exists for, proven with one already-pulled
# Ollama model rather than needing a second one downloaded just for this
# spec. Same free-recording reasoning as `start_spec.cr`.
private MODEL = "gemma4:26b-mxfp8"

private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "elelem-cli-continue-spec-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(File.join(tmp, ".elelem"))
  config_path = File.join(tmp, "elelem.yaml")
  File.write(config_path, <<-YAML)
    servers:
      ollama:
        protocol: chat_completions
        url: http://localhost:11434
      ollama-responses:
        protocol: responses
        url: http://localhost:11434
    deployments:
      ollama:
        server: ollama
        model: #{MODEL}
      ollama-responses:
        server: ollama-responses
        model: #{MODEL}
    YAML

  # See start_spec.cr's with_sandbox for why this is $ELELEM_CONFIG /
  # $ELELEM_HOME rather than Dir.cd or a bare $HOME override.
  original_home = ENV["ELELEM_HOME"]?
  original_config = ENV["ELELEM_CONFIG"]?
  ENV["ELELEM_HOME"] = File.join(tmp, ".elelem")
  ENV["ELELEM_CONFIG"] = config_path
  begin
    yield
  ensure
    original_home ? (ENV["ELELEM_HOME"] = original_home) : ENV.delete("ELELEM_HOME")
    original_config ? (ENV["ELELEM_CONFIG"] = original_config) : ENV.delete("ELELEM_CONFIG")
    FileUtils.rm_rf(tmp)
  end
end

# Shared name deliberately: both specs below start from the same deployment
# with the same prompt, so the request is byte-identical — the same rule
# `ollama_spec.cr` already documents for sharing a transcript name.
private def started : String
  Wiretap.intercept("elelem_cli_continue_start") do
    Elelem::Cli::Commands::Start.run(["ollama", "What is the tallest mountain on Earth?",
                                      "Answer in one short sentence."])
  end
  Dir.children(Elelem::Cli::Sessions.folder).first
end

describe Elelem::Cli::Commands::Continue do
  it "reuses the last deployment when --on is not given" do
    with_sandbox do
      id = started

      Wiretap.intercept("elelem_cli_continue_same_deployment") do
        Elelem::Cli::Commands::Continue.run([id, "Why is that?"])
      end

      Elelem::Cli::Sessions.latest_deployment(id).should eq("ollama")
      Elelem::Cli::Sessions.latest(id).messages.size.should eq(4)
    end
  end

  it "switches deployment when --on is given, carrying the session to a different protocol" do
    with_sandbox do
      id = started

      Wiretap.intercept("elelem_cli_continue_switch") do
        Elelem::Cli::Commands::Continue.run([id, "Why is that?", "--on", "ollama-responses"])
      end

      Elelem::Cli::Sessions.latest_deployment(id).should eq("ollama-responses")
      Elelem::Cli::Sessions.latest(id).messages.size.should eq(4)
    end
  end

  it "raises naming the session id when asked to continue one that never started" do
    with_sandbox do
      expect_raises(Elelem::Cli::SessionError, /nonexistent-session/) do
        Elelem::Cli::Commands::Continue.run(["nonexistent-session", "hello"])
      end
    end
  end

  it "raises a usage error when no prompt is given" do
    with_sandbox do
      expect_raises(ArgumentError, /usage/) do
        Elelem::Cli::Commands::Continue.run(["any-id-at-all"])
      end
    end
  end
end
