require "http/client"
require "uri"
require "./streaming/sse"

module Elelem
  # A live call failed at the transport, not at the translation.
  #
  # Kept apart from `Protocol::MalformedResponseError`, which means the body
  # arrived and could not be read. A 429 and a truncated reply are different
  # problems for a caller — one is worth waiting on, the other never will be —
  # and collapsing them would make any future retry logic guess.
  class TransportError < Exception
    getter status : Int32
    getter server : String
    # Whatever the protocol could salvage from the error body. Populated by the
    # adapter, because the shape of an error object is protocol-specific:
    # Anthropic's `{"type":"error", ...}` looks nothing like Gemini's.
    getter detail : String?

    def initialize(@server : String, @status : Int32, @detail : String? = nil)
      super(@detail ? "#{@server}: HTTP #{@status} — #{@detail}" : "#{@server}: HTTP #{@status}")
    end

    # Worth trying again later; the request itself was not the problem.
    def transient? : Bool
      @status == 429 || @status >= 500
    end
  end

  class AuthError < TransportError; end

  class ModelNotFoundError < TransportError; end

  class RateLimitedError < TransportError; end

  class OverloadedError < TransportError; end

  # A streamed generation failed after the response had already begun.
  #
  # **A sibling of `TransportError`, deliberately not a subclass.** Once the
  # outer status is committed at 200 there is no status left to describe the
  # failure, so a mid-stream error arrives as an error frame in place of the
  # terminal one. Inheriting would bring `status` along, and `status` would
  # have to lie — either repeating the 200 that succeeded or inventing a code
  # the server never sent. It would also inherit `transient?`, and the
  # distinction that method exists to draw is exactly the one being lost: a 429
  # is worth waiting on, this is not.
  #
  # `type` is the vendor's own name for what went wrong, taken from the error
  # frame verbatim. Nullable because a frame may carry no type at all, and
  # inventing one would put a guess where a caller expects a provider's word.
  class StreamError < Exception
    getter server : String
    getter type : String?

    def initialize(@server : String, detail : String, @type : String? = nil)
      super(@type ? "#{@server}: #{@type} — #{detail}" : "#{@server}: #{detail}")
    end
  end

  # One deployment: a host, a credential, and the connection to it.
  #
  # The connection lives here rather than on `Provider` because it belongs to
  # the host. Ollama serves three protocols from one port, so three providers
  # share one server and one keep-alive socket between them; hanging the
  # connection off the provider would open three.
  #
  # `name` is the deployment's own identity, and it does real work: a provider
  # only inherits a protocol's vendor authenticity when the two agree. A server
  # named `ollama` speaking the Anthropic protocol is not Anthropic, and the
  # default falls out of that comparison rather than needing a flag.
  class Server
    getter name : String
    getter base_uri : URI
    getter credential : String?

    def initialize(@name : String, base_url : String, @credential : String? = nil,
                   @timeout : Time::Span = 120.seconds)
      @base_uri = URI.parse(base_url)
    end

    # Separate from anything that reads a reply body, so streaming has
    # somewhere to go later without disturbing either side of it.
    #
    # `detail` is the protocol's error-body decoder. Status classification is
    # this class's job and near-universal; reading the error object is the
    # adapter's, because the shape differs per protocol. Passing it in keeps
    # both facts where they belong and still raises a single, complete error.
    def post(path : String, headers : HTTP::Headers, body : String,
             detail : Proc(String, String?)? = nil) : String
      response = client.post(path, headers: headers, body: body)
      return response.body if response.success?

      explanation = detail.try(&.call(response.body))
      raise error_for(response.status_code, explanation)
    end

    # The streaming half of `post`, and the seam this class's comment promised.
    #
    # Frames are yielded as they arrive. The block answers `true` to carry on
    # and `false` to stop early, which is clumsier than letting it `break` and
    # is chosen for one reason: **this method has to know that it stopped.** A
    # stream abandoned part-way leaves a socket positioned in the middle of a
    # response body, and this server's connection is shared — Ollama serves
    # three protocols from one port through one keep-alive socket. Handing that
    # socket to the next request would fail somewhere far away from here. So an
    # early stop drops the connection, and the next call opens a fresh one.
    #
    # Status handling is identical to `post`'s, because a pre-request rejection
    # is a pre-request rejection whether or not a stream was asked for: it
    # arrives as a status before any frame, and `error_for` classifies it
    # unchanged. Everything that can go wrong *after* the 200 is the
    # assembler's to notice.
    def stream(path : String, headers : HTTP::Headers, body : String,
               detail : Proc(String, String?)? = nil,
               & : Streaming::Sse::Frame -> Bool) : Nil
      stopped = false

      client.post(path, headers: headers, body: body) do |response|
        unless response.success?
          explanation = detail.try(&.call(response.body_io.gets_to_end))
          raise error_for(response.status_code, explanation)
        end

        Streaming::Sse.each_frame(response.body_io) do |frame|
          unless yield frame
            stopped = true
            break
          end
        end
      end

      close if stopped
    end

    # Status is near-universal HTTP and belongs here.
    def error_for(status : Int32, detail : String? = nil) : TransportError
      case status
      when 401, 403 then AuthError.new(@name, status, detail)
      when 404      then ModelNotFoundError.new(@name, status, detail)
      when 429      then RateLimitedError.new(@name, status, detail)
      when .>=(500) then OverloadedError.new(@name, status, detail)
      else               TransportError.new(@name, status, detail)
      end
    end

    def close : Nil
      @client.try &.close
      @client = nil
    end

    private def client : HTTP::Client
      @client ||= HTTP::Client.new(@base_uri).tap do |http|
        http.read_timeout = @timeout
        http.connect_timeout = @timeout
      end
    end

    @client : HTTP::Client? = nil
  end
end
