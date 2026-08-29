require "../../spec_helper"
require "file_utils"
require "../../../src/elelem_cli/config"
require "../../../src/elelem_cli/sessions"
require "../../../src/elelem_cli/commands/start"

# In-process, same reasoning as every other spec in this shard: a compiler
# error surfaces directly here rather than inside a subprocess. `Start.run`
# goes through the real `Server#post`, so Wiretap intercepts it exactly like
# `spec/live/ollama_spec.cr` does — record once against a local Ollama with
# `RECORD=1`, replays offline for everyone after. Free: local, no API key.
private MODEL = "gemma4:26b-mxfp8"

private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "elelem-cli-start-spec-#{Random.rand(1_000_000)}")
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
    YAML

  # $ELELEM_CONFIG / $ELELEM_HOME, not Dir.cd and not relying on an
  # unshadowed $CWD or $HOME. Two separate reasons: Dir.cd would move
  # Wiretap's own relative transcript path into this sandbox too — the
  # earlier bug — and a real elelem.yaml or .elelem left by an actual `elelem`
  # invocation on this machine would otherwise win over the sandboxed one,
  # since $CWD is checked before either explicit override.
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

describe Elelem::Cli::Commands::Start do
  it "creates a session, saves it, and records which deployment answered" do
    with_sandbox do
      Wiretap.intercept("elelem_cli_start_ollama") do
        Elelem::Cli::Commands::Start.run(["ollama", "What is the tallest mountain on Earth?",
                                          "Answer in one short sentence."])
      end

      ids = Dir.children(Elelem::Cli::Sessions.folder)
      ids.size.should eq(1)
      id = ids.first

      Elelem::Cli::Sessions.latest_deployment(id).should eq("ollama")

      session = Elelem::Cli::Sessions.latest(id)
      session.messages.size.should eq(2)
      session.messages.first.role.should eq(M::Role::User)
      session.messages.last.role.should eq(M::Role::Assistant)
      session.messages.last.content.select(M::TextBlock).should_not be_empty
    end
  end

  # Both of these raise before the request is made, so they need no cassette.
  # That is also the behaviour under test: a refusal is only useful if it
  # arrives before the money is spent.
  it "refuses an --id that is already a session, and points at continue" do
    with_sandbox do
      Dir.mkdir_p(Elelem::Cli::Sessions.path_for("tax-questions"))
      expect_raises(Elelem::Cli::SessionError, /already exists.*elelem continue tax-questions/) do
        Elelem::Cli::Commands::Start.run(["ollama", "hello", "--id", "tax-questions"])
      end
    end
  end

  it "refuses an --id that would leave the sessions folder" do
    with_sandbox do
      expect_raises(Elelem::Cli::SessionError, /not a usable session id/) do
        Elelem::Cli::Commands::Start.run(["ollama", "hello", "--id", "../escape"])
      end
    end
  end

  it "raises naming the deployment, before ever calling out, for an unknown one" do
    with_sandbox do
      expect_raises(Elelem::Cli::ConfigError, /"nonexistent"/) do
        Elelem::Cli::Commands::Start.run(["nonexistent", "hello"])
      end
    end
  end

  it "raises a usage error when no prompt is given" do
    with_sandbox do
      expect_raises(ArgumentError, /usage/) do
        Elelem::Cli::Commands::Start.run(["ollama"])
      end
    end
  end
end
