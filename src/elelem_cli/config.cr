require "yaml"
require "../elelem"

module Elelem::Cli
  class ConfigError < Exception
  end

  # One named entry in `elelem.yaml`. Deliberately not `ProtocolKind` directly
  # in the config file's own vocabulary — the file says "anthropic",
  # "chat_completions", "responses", "gemini", parsed here, not `Provider`'s
  # problem.
  struct Deployment
    getter protocol : ProtocolKind
    getter server_url : String
    getter model : String
    getter credential_env : String?
    getter? azure : Bool
    getter api_version : String?
    getter max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField?

    def initialize(@protocol : ProtocolKind, @server_url : String, @model : String,
                   @credential_env : String? = nil, @azure : Bool = false,
                   @api_version : String? = nil,
                   @max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField? = nil)
    end

    # `nil` here, silently, is deliberate: an unset credential means an
    # unauthenticated call, which some deployments (a local Ollama) genuinely
    # want. What this does *not* do is warn about a set-but-empty environment
    # variable — that failure surfaces as a 401 from the server itself, which
    # already carries more information than a guess made here could.
    def credential : String?
      credential_env.try { |name| ENV[name]? }
    end
  end

  class Config
    getter deployments : Hash(String, Deployment)

    def initialize(@deployments : Hash(String, Deployment))
    end

    # `$CWD/elelem.yaml`, then `$HOME/elelem.yaml`. See `docs/CLI_DESIGN.md`.
    def self.load : Config
      path = locate || raise ConfigError.new(
        "no elelem.yaml found in #{Dir.current} or $HOME — see docs/CLI_DESIGN.md for the format")
      from_yaml(File.read(path))
    end

    def self.locate : String?
      cwd_candidate = File.join(Dir.current, "elelem.yaml")
      return cwd_candidate if File.exists?(cwd_candidate)

      if home = ENV["HOME"]?
        home_candidate = File.join(home, "elelem.yaml")
        return home_candidate if File.exists?(home_candidate)
      end

      nil
    end

    def self.from_yaml(text : String) : Config
      root = YAML.parse(text)
      table = root["deployments"]?.try(&.as_h?) || raise ConfigError.new("elelem.yaml has no 'deployments' key")

      deployments = {} of String => Deployment
      table.each do |key, node|
        name = key.as_s
        deployments[name] = parse_deployment(name, node)
      end

      new(deployments)
    end

    private def self.parse_deployment(name : String, node : YAML::Any) : Deployment
      protocol_name = node["protocol"]?.try(&.as_s?) ||
                      raise ConfigError.new("deployment #{name.inspect} has no 'protocol'")
      server_url = node["server"]?.try(&.as_s?) ||
                   raise ConfigError.new("deployment #{name.inspect} has no 'server'")
      model = node["model"]?.try(&.as_s?) ||
              raise ConfigError.new("deployment #{name.inspect} has no 'model'")

      Deployment.new(
        protocol: parse_protocol(name, protocol_name),
        server_url: server_url,
        model: model,
        credential_env: node["credential_env"]?.try(&.as_s?),
        azure: node["azure"]?.try(&.as_bool?) || false,
        api_version: node["api_version"]?.try(&.as_s?),
        max_tokens_field: node["max_tokens_field"]?.try(&.as_s?).try { |field| parse_max_tokens_field(name, field) },
      )
    end

    private def self.parse_protocol(name : String, protocol_name : String) : ProtocolKind
      case protocol_name
      when "chat_completions" then ProtocolKind::ChatCompletions
      when "responses"        then ProtocolKind::Responses
      when "anthropic"        then ProtocolKind::Anthropic
      when "gemini"           then ProtocolKind::Gemini
      else
        raise ConfigError.new("deployment #{name.inspect} has unrecognised protocol #{protocol_name.inspect} " \
                              "— expected chat_completions, responses, anthropic, or gemini")
      end
    end

    private def self.parse_max_tokens_field(name : String,
                                            field : String) : Protocol::ChatCompletions::Wire::MaxTokensField
      case field
      when "max_tokens"            then Protocol::ChatCompletions::Wire::MaxTokensField::MaxTokens
      when "max_completion_tokens" then Protocol::ChatCompletions::Wire::MaxTokensField::MaxCompletionTokens
      else
        raise ConfigError.new("deployment #{name.inspect} has unrecognised max_tokens_field #{field.inspect} " \
                              "— expected max_tokens or max_completion_tokens")
      end
    end

    def deployment(name : String) : Deployment
      deployments[name]? || raise ConfigError.new(
        "no deployment named #{name.inspect} in elelem.yaml — have: #{deployments.keys.join(", ")}")
    end

    # The deployment name is also the `Server`'s own name, deliberately — it's
    # what lets `Provider.for`'s existing vendor default work unchanged: a
    # deployment the operator called `anthropic` is treated as authentically
    # Anthropic by the same comparison every other caller already relies on.
    def provider_for(name : String) : Provider
      d = deployment(name)
      server = Server.new(name, d.server_url, d.credential)

      if d.azure?
        api_version = d.api_version || raise ConfigError.new(
          "deployment #{name.inspect} has azure: true but no api_version")
        Provider.for_azure(server, d.protocol, api_version, max_tokens_field: d.max_tokens_field)
      else
        Provider.for(server, d.protocol, max_tokens_field: d.max_tokens_field)
      end
    end
  end
end
