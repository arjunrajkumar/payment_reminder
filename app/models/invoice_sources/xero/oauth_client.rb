require "json"
require "net/http"
require "openssl"
require "uri"

module InvoiceSources
  class Xero
    class OauthClient
      class Error < StandardError; end

      INVOICES_PAGE_SIZE = 1_000

      attr_reader :config

      def initialize(config: Configuration.new)
        @config = config
      end

      def authorization_url(state:, redirect_uri: config.redirect_uri, scopes: config.scopes, nonce: nil)
        uri = config.authorization_uri.dup
        query = {
          response_type: "code",
          client_id: config.client_id,
          redirect_uri: redirect_uri,
          scope: Array(scopes).join(" "),
          state: state
        }
        query[:nonce] = nonce if nonce.present?
        uri.query = Rack::Utils.build_query(query)
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

      def connections(access_token:, auth_event_id: nil)
        uri = config.connections_uri.dup
        uri.query = Rack::Utils.build_query(authEventId: auth_event_id) if auth_event_id.present?

        get_json(uri, access_token: access_token)
      end

      def userinfo(access_token:)
        get_json(config.userinfo_uri, access_token: access_token)
      rescue Error
        {}
      end

      def jwks
        get_json(config.jwks_uri)
      end

      def invoices(access_token:, tenant_id:, where: nil)
        page = 1
        invoices = []
        first_payload = nil

        loop do
          payload = get_json(
            invoices_uri(page:, where:),
            access_token:,
            tenant_id:
          )
          first_payload ||= payload
          page_invoices = Array(payload.fetch("Invoices", []))
          invoices.concat(page_invoices)

          break if last_invoices_page?(payload:, page:, page_invoices:)

          page += 1
        end

        first_payload.except("pagination").merge("Invoices" => invoices)
      end

      def invoice(access_token:, tenant_id:, invoice_id:)
        get_json(config.invoice_uri(invoice_id), access_token: access_token, tenant_id: tenant_id)
      end

      def online_invoice(access_token:, tenant_id:, invoice_id:)
        get_json(config.online_invoice_uri(invoice_id), access_token: access_token, tenant_id: tenant_id)
      end

      private
        def invoices_uri(page:, where:)
          uri = config.invoices_uri.dup
          query = { page:, pageSize: INVOICES_PAGE_SIZE }
          query[:where] = where if where.present?
          uri.query = Rack::Utils.build_query(query)
          uri
        end

        def last_invoices_page?(payload:, page:, page_invoices:)
          page_count = payload.dig("pagination", "pageCount")
          return page >= page_count.to_i if page_count.present?

          page_invoices.size < INVOICES_PAGE_SIZE
        end

        def post_token(form)
          request = Net::HTTP::Post.new(config.token_uri)
          request.basic_auth(config.client_id, config.client_secret)
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request.set_form_data(form)

          request_json(config.token_uri, request)
        end

        def get_json(uri, access_token: nil, tenant_id: nil)
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{access_token}" if access_token.present?
          request["Accept"] = "application/json"
          request["xero-tenant-id"] = tenant_id if tenant_id.present?

          request_json(uri, request)
        end

        def request_json(uri, request)
          response = Net::HTTP.start(
            uri.hostname,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: 5,
            read_timeout: 10
          ) do |http|
            http.request(request)
          end

          body = response.body.presence || "{}"
          parsed_body = JSON.parse(body)

          return parsed_body if response.is_a?(Net::HTTPSuccess)

          message = parsed_body["error_description"] || parsed_body["error"] || response.message
          raise Error, message
        rescue JSON::ParserError
          raise Error, "Xero returned an invalid response."
        rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => error
          raise Error, "Xero request failed: #{error.message}"
        end
    end
  end
end
