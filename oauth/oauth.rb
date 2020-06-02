# frozen_string_literal: true

require 'oauth'

require_relative 'xauth'

module Plugin::Twitter
  class OAuth
    def initialize(ck, cs)
      @consumer = ::OAuth::Consumer.new ck, cs, site: 'https://api.twitter.com'
    end

    def authorize_url
      @request_token ||= @consumer.get_request_token
      @request_token.authorize_url
    end

    def authorize(pin)
      Deferred.new do
        @request_token.get_access_token oauth_verifier: pin
        [@request_token.token, @request_token.secret]
      end
    end
  end
end
