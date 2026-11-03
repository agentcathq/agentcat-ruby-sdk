# typed: true

require "net/http"
require "timeout"
require "uri"

module AgentCat
  # Shared by every HTTP exporter and the diagnostics beacon. Callers pick their own
  # timeouts. Doesn't raise on
  # a non-2xx response — the caller decides what that means.
  #
  # `open_timeout`/`read_timeout` are per step (a server that trickles bytes never
  # trips `read_timeout`); `deadline`, when given, bounds the whole request, DNS
  # lookup included, and raises Timeout::Error when it runs out.
  module HttpPost
    class << self
      extend T::Sig

      sig do
        params(
          url: String,
          headers: T::Hash[String, String],
          body: String,
          open_timeout: Numeric,
          read_timeout: Numeric,
          deadline: T.nilable(Numeric)
        ).returns([Integer, String])
      end
      def call(url, headers, body, open_timeout:, read_timeout:, deadline: nil)
        return post(url, headers, body, open_timeout, read_timeout) if deadline.nil?

        Timeout.timeout(deadline) { post(url, headers, body, open_timeout, read_timeout) }
      end

      private

      sig do
        params(
          url: String,
          headers: T::Hash[String, String],
          body: String,
          open_timeout: Numeric,
          read_timeout: Numeric
        ).returns([Integer, String])
      end
      def post(url, headers, body, open_timeout, read_timeout)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http.write_timeout = read_timeout

        request = Net::HTTP::Post.new(T.unsafe(uri).request_uri, headers)
        request.body = body
        response = http.request(request)
        [response.code.to_i, response.body.to_s]
      end
    end
  end
end
