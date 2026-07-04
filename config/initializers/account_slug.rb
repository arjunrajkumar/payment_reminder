module AccountSlug
  PATTERN = /(\d+)/
  PATH_INFO_MATCH = /\A(\/#{AccountSlug::PATTERN})/

  class Extractor
    def initialize(app)
      @app = app
    end

    # Treat a leading account id path segment as the Rails script name, so
    # normal routes can serve both scoped and unscoped URLs.
    def call(env)
      request = ActionDispatch::Request.new(env)

      if request.script_name && request.script_name =~ PATH_INFO_MATCH
        env["paidjar.external_account_id"] = AccountSlug.decode($2)
      elsif request.path_info =~ PATH_INFO_MATCH
        request.engine_script_name = request.script_name = $1
        request.path_info = $'.empty? ? "/" : $'

        env["paidjar.external_account_id"] = AccountSlug.decode($2)
      end

      if env["paidjar.external_account_id"]
        account = Account.find_by(external_account_id: env["paidjar.external_account_id"])
        Current.with_account(account) { @app.call env }
      else
        Current.without_account { @app.call env }
      end
    end
  end

  def self.decode(slug) = slug.to_i
  def self.encode(id) = id.to_s
end

Rails.application.config.middleware.insert_after Rack::TempfileReaper, AccountSlug::Extractor
