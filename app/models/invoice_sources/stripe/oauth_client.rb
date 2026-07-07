require "json"
require "net/http"
require "uri"

module InvoiceSources
  class Stripe
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
          scope: config.scope,
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

      def invoices(stripe_account_id:)
        data = []
        starting_after = nil

        loop do
          payload = list_invoices(stripe_account_id: stripe_account_id, starting_after: starting_after)
          batch = Array(payload["data"])
          data.concat(batch)

          break unless payload["has_more"] && batch.any?

          starting_after = batch.last.fetch("id")
        end

        { "data" => data }
      end

      def invoice(stripe_account_id:, invoice_id:)
        get_json(config.invoice_uri(invoice_id), stripe_account_id: stripe_account_id)
      end

      private
        def post_token(form)
          request = Net::HTTP::Post.new(config.token_uri)
          request.basic_auth(config.secret_key, "")
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request.set_form_data(form)

          request_json(config.token_uri, request)
        end

        def list_invoices(stripe_account_id:, starting_after:)
          uri = config.invoices_uri.dup
          query = { limit: 100 }
          query[:starting_after] = starting_after if starting_after.present?
          uri.query = Rack::Utils.build_query(query)

          get_json(uri, stripe_account_id: stripe_account_id)
        end

        def get_json(uri, stripe_account_id:)
          request = Net::HTTP::Get.new(uri)
          request.basic_auth(config.secret_key, "")
          request["Accept"] = "application/json"
          request["Stripe-Account"] = stripe_account_id

          request_json(uri, request)
        end

        def request_json(uri, request)
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(request)
          end

          body = response.body.presence || "{}"
          parsed_body = JSON.parse(body)

          return parsed_body if response.is_a?(Net::HTTPSuccess)

          message = parsed_body.dig("error", "message") || parsed_body["error_description"] || parsed_body["error"] || response.message
          raise Error, message
        rescue JSON::ParserError
          raise Error, "Stripe returned an invalid response."
        end
    end
  end
end
