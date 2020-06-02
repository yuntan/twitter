# frozen_string_literal: true

module Plugin::Twitter
  class XAuth
    def initialize(ck, cs)
      @consumer = ::OAuth::Consumer.new ck, cs, site: 'https://api.twitter.com'
    end

    def authorize(username, password)
      Deferred.new do
        @access_token = @consumer.get_access_token(nil, {}, {
          x_auth_mode: 'client_auth',
          x_auth_username: username,
          x_auth_password: password,
        })
        [@access_token.token, @access_token.secret]
      end
    end
  end
end
