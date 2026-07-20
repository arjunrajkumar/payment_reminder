module Xero
  class Jwks
    CACHE_KEY = "xero/oidc/jwks"
    EXPIRES_IN = 1.hour

    def initialize(client: InvoiceSources::Xero::OauthClient.new, cache: Rails.cache)
      @client = client
      @cache = cache
    end

    def call(options = {})
      cache.delete(CACHE_KEY) if options[:invalidate]
      cache.fetch(CACHE_KEY, expires_in: EXPIRES_IN) { client.jwks }
    end

    private
      attr_reader :client, :cache
  end
end
