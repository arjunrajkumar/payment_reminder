require "json"
require "net/http"
require "uri"

module InvoiceSources
  class Xero
    class OauthClient
      class Error < StandardError; end

      attr_reader :config

      def initialize(config: Configuration.new)
        @config = config
      end

      def authorization_url(state:, redirect_uri: config.redirect_uri)
        uri = config.authorization_uri.dup
        uri.query = Rack::Utils.build_query(
          response_type: "code",
          client_id: config.client_id,
          redirect_uri: redirect_uri,
          scope: config.scopes,
          state: state
        )
        uri.to_s
      end

      def exchange_code(code:, redirect_uri: config.redirect_uri)
        post_token(
          grant_type: "authorization_code",
          code: code,
          redirect_uri: redirect_uri
        )
      end

      def refresh_token(refresh_token:)
        post_token(
          grant_type: "refresh_token",
          refresh_token: refresh_token
        )
      end

      def connections(access_token:)
        get_json(config.connections_uri, access_token: access_token)
      end

      def userinfo(access_token:)
        get_json(config.userinfo_uri, access_token: access_token)
      rescue Error
        {}
      end

      def invoices(access_token:, tenant_id:, where: nil)
        uri = config.invoices_uri.dup
        uri.query = Rack::Utils.build_query(where: where) if where.present?

        get_json(uri, access_token: access_token, tenant_id: tenant_id)
      end

      def invoice(access_token:, tenant_id:, invoice_id:)
        get_json(config.invoice_uri(invoice_id), access_token: access_token, tenant_id: tenant_id)
      end

      private
        def post_token(form)
          request = Net::HTTP::Post.new(config.token_uri)
          request.basic_auth(config.client_id, config.client_secret)
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request.set_form_data(form)

          request_json(config.token_uri, request)
        end

        def get_json(uri, access_token:, tenant_id: nil)
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{access_token}"
          request["Accept"] = "application/json"
          request["xero-tenant-id"] = tenant_id if tenant_id.present?

          request_json(uri, request)
        end

        def request_json(uri, request)
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(request)
          end

          body = response.body.presence || "{}"
          parsed_body = JSON.parse(body)

          return parsed_body if response.is_a?(Net::HTTPSuccess)

          message = parsed_body["error_description"] || parsed_body["error"] || response.message
          raise Error, message
        rescue JSON::ParserError
          raise Error, "Xero returned an invalid response."
        end
    end
  end
end
