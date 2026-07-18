require "test_helper"

class OutboundEmailConnection::Gmail::OauthClientTest < ActiveSupport::TestCase
  setup do
    @config = FakeConfiguration.new
    @client = OutboundEmailConnection::Gmail::OauthClient.new(config: @config)
  end

  test "authorization requests offline consent with the required Gmail scopes" do
    uri = URI(@client.authorization_url(
      state: "signed-state",
      redirect_uri: "https://example.com/gmail/callback"
    ))
    params = Rack::Utils.parse_query(uri.query)

    assert_equal "offline", params["access_type"]
    assert_equal "consent", params["prompt"]
    assert_equal "signed-state", params["state"]
    assert_equal "true", params["include_granted_scopes"]
    assert_equal @config.scopes.sort, params.fetch("scope").split.sort
  end

  test "refreshes tokens without a real Google request" do
    stub_request(:post, @config.token_uri.to_s)
      .with(body: hash_including(
        "grant_type" => "refresh_token",
        "refresh_token" => "refresh-token"
      ))
      .to_return(
        status: 200,
        body: { access_token: "new-token", expires_in: 3600 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    token_data = @client.refresh_token(refresh_token: "refresh-token")

    assert_equal "new-token", token_data.fetch("access_token")
  end

  test "classifies a revoked refresh token as an authentication error" do
    stub_request(:post, @config.token_uri.to_s).to_return(
      status: 400,
      body: { error: "invalid_grant" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_raises OutboundEmailConnection::Errors::AuthenticationError do
      @client.refresh_token(refresh_token: "revoked-token")
    end
  end

  class FakeConfiguration
    def client_id = "google-client-id"
    def client_secret = "google-client-secret"
    def scopes = OutboundEmailConnection::Gmail::Configuration::SCOPES
    def authorization_uri = URI("https://accounts.google.test/authorize")
    def token_uri = URI("https://oauth2.google.test/token")
    def userinfo_uri = URI("https://google.test/userinfo")
  end
end
