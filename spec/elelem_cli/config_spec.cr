require "../spec_helper"
require "../../src/elelem_cli/config"

# Pure by construction: `Config.from_yaml` is a string in, a `Config` or a
# raised `ConfigError` out. No `Dir.cd`, no temp files — see
# `sessions_spec.cr` for the specs that actually need a sandbox.
describe Elelem::Cli::Config do
  describe ".from_yaml" do
    it "parses a server and a deployment pointing at it" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        servers:
          anthropic:
            protocol: anthropic
            url: https://api.anthropic.com
            credential_env: ANTHROPIC_API_KEY
        deployments:
          haiku:
            server: anthropic
            model: claude-haiku-4-5
        YAML

      d = config.deployment("haiku")
      d.model.should eq("claude-haiku-4-5")
      d.protocol.should eq(Elelem::ProtocolKind::Anthropic)
      d.server.url.should eq("https://api.anthropic.com")
      d.server.credential_env.should eq("ANTHROPIC_API_KEY")
      d.server.azure.should be_nil
    end

    # The repetition this restructure exists to remove.
    it "lets many deployments share one server" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        servers:
          ollama:
            protocol: chat_completions
            url: http://localhost:11434/v1
        deployments:
          qwen:
            server: ollama
            model: qwen3.8
          gemma:
            server: ollama
            model: gemma4-27b
        YAML

      config.deployments.size.should eq(2)
      config.deployment("qwen").server.url.should eq(config.deployment("gemma").server.url)
      config.deployment("qwen").model.should eq("qwen3.8")
      config.deployment("gemma").model.should eq("gemma4-27b")
    end

    it "parses an azure block and max_tokens_field on the server" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        servers:
          azure-alpha:
            protocol: chat_completions
            url: https://oxaro-alpha.openai.azure.com
            credential_env: AZURE_OPENAI_API_KEY
            max_tokens_field: max_completion_tokens
            azure:
              api_version: "2025-04-01-preview"
        deployments:
          azure-mini:
            server: azure-alpha
            model: gpt5.4mini
        YAML

      s = config.deployment("azure-mini").server
      s.azure.not_nil!.api_version.should eq("2025-04-01-preview")
      s.max_tokens_field.should eq(Elelem::Protocol::ChatCompletions::Wire::MaxTokensField::MaxCompletionTokens)
    end

    it "leaves azure and max_tokens_field absent when not given" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        servers:
          ollama:
            protocol: chat_completions
            url: http://localhost:11434
        deployments:
          home:
            server: ollama
            model: llama3.2
        YAML

      s = config.deployment("home").server
      s.azure.should be_nil
      s.max_tokens_field.should be_nil
    end

    # The whole point of the nested block: this shape used to be writable and
    # failed later, at provider construction.
    it "raises at parse time for an azure block with no api_version" do
      expect_raises(Elelem::Cli::ConfigError, /api_version/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            azure-alpha:
              protocol: chat_completions
              url: https://example.openai.azure.com
              azure:
                region: eastus
          deployments:
            mini:
              server: azure-alpha
              model: gpt5.4mini
          YAML
      end
    end

    it "raises when 'servers' is missing entirely" do
      expect_raises(Elelem::Cli::ConfigError, /servers/) do
        Elelem::Cli::Config.from_yaml("default_deployment: anthropic")
      end
    end

    it "raises when 'deployments' is missing entirely" do
      expect_raises(Elelem::Cli::ConfigError, /deployments/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            ollama:
              protocol: chat_completions
              url: http://localhost:11434
          YAML
      end
    end

    # An old config parses as a deployment referencing a server *named* after
    # a URL. The error it would otherwise give is accurate and useless.
    it "recognises the old flat format and says what to change" do
      expect_raises(Elelem::Cli::ConfigError, /format changed.*servers:/m) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          deployments:
            anthropic:
              protocol: anthropic
              server: https://api.anthropic.com
              model: claude-haiku-4-5
          YAML
      end
    end

    it "raises naming the deployment when its server is not defined" do
      expect_raises(Elelem::Cli::ConfigError, /"qwen".*"typo-ollama".*not defined/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            ollama:
              protocol: chat_completions
              url: http://localhost:11434
          deployments:
            qwen:
              server: typo-ollama
              model: qwen3.8
          YAML
      end
    end

    it "raises naming the server when 'protocol' is missing" do
      expect_raises(Elelem::Cli::ConfigError, /"anthropic".*protocol/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            anthropic:
              url: https://api.anthropic.com
          deployments:
            haiku:
              server: anthropic
              model: claude-haiku-4-5
          YAML
      end
    end

    it "raises naming the server when 'url' is missing" do
      expect_raises(Elelem::Cli::ConfigError, /"anthropic".*url/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            anthropic:
              protocol: anthropic
          deployments:
            haiku:
              server: anthropic
              model: claude-haiku-4-5
          YAML
      end
    end

    it "raises naming the deployment when 'model' is missing" do
      expect_raises(Elelem::Cli::ConfigError, /"haiku".*model/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            anthropic:
              protocol: anthropic
              url: https://api.anthropic.com
          deployments:
            haiku:
              server: anthropic
          YAML
      end
    end

    it "raises on an unrecognised protocol" do
      expect_raises(Elelem::Cli::ConfigError, /unrecognised protocol "azure-native"/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            weird:
              protocol: azure-native
              url: https://example.com
          deployments:
            w:
              server: weird
              model: whatever
          YAML
      end
    end

    it "raises on an unrecognised max_tokens_field" do
      expect_raises(Elelem::Cli::ConfigError, /unrecognised max_tokens_field "output_limit"/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          servers:
            weird:
              protocol: chat_completions
              url: https://example.com
              max_tokens_field: output_limit
          deployments:
            w:
              server: weird
              model: whatever
          YAML
      end
    end
  end

  describe "#deployment" do
    it "raises listing the known deployment names when asked for an unknown one" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        servers:
          anthropic:
            protocol: anthropic
            url: https://api.anthropic.com
        deployments:
          haiku:
            server: anthropic
            model: claude-haiku-4-5
        YAML

      expect_raises(Elelem::Cli::ConfigError, /"azure-mini".*haiku/) { config.deployment("azure-mini") }
    end
  end

  describe "#provider_for" do
    # The vendor claim now follows the *server* name, not the deployment name.
    # That is the change the split makes, and it is the right way round:
    # `haiku` and `sonnet` are two deployments of one endpoint, and the
    # endpoint is what is or is not authentically Anthropic.
    it "names the Provider's Server for the server entry, not the deployment" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        servers:
          anthropic:
            protocol: anthropic
            url: https://api.anthropic.com
        deployments:
          haiku:
            server: anthropic
            model: claude-haiku-4-5
        YAML

      provider = config.provider_for("haiku")
      provider.server.name.should eq("anthropic")
      provider.adapter.class.should eq(Elelem::AnthropicAdapter)
    end

    it "builds an Azure Provider via Provider.for_azure" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        servers:
          azure-alpha:
            protocol: chat_completions
            url: https://oxaro-alpha.openai.azure.com
            azure:
              api_version: "2025-04-01-preview"
        deployments:
          azure-mini:
            server: azure-alpha
            model: gpt5.4mini
        YAML

      provider = config.provider_for("azure-mini")
      provider.server.name.should eq("azure-alpha")
      provider.adapter.class.should eq(Elelem::AzureChatCompletionsAdapter)
    end
  end

  describe Elelem::Cli::ServerConfig do
    it "resolves credential from the named environment variable" do
      ENV["ELELEM_SPEC_TEST_KEY"] = "shh"
      begin
        s = Elelem::Cli::ServerConfig.new("x", Elelem::ProtocolKind::Anthropic, "https://example.com",
          credential_env: "ELELEM_SPEC_TEST_KEY")
        s.credential.should eq("shh")
      ensure
        ENV.delete("ELELEM_SPEC_TEST_KEY")
      end
    end

    it "is nil when credential_env is unset" do
      s = Elelem::Cli::ServerConfig.new("x", Elelem::ProtocolKind::ChatCompletions, "http://localhost:11434")
      s.credential.should be_nil
    end
  end
end
