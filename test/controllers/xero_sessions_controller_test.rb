require "test_helper"

class XeroSessionsControllerTest < ActionDispatch::IntegrationTest
  test "start is public and requests only Xero identity scopes with state and nonce" do
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_session_url
    end

    assert_redirected_to FakeXeroClient::AUTHORIZATION_URL
    assert fake_client.authorization_options.fetch(:state).present?
    assert fake_client.authorization_options.fetch(:nonce).present?
    assert_equal InvoiceSources::Xero::Configuration.new.session_redirect_uri,
      fake_client.authorization_options.fetch(:redirect_uri)
    assert_equal %w[email openid profile], requested_scopes(fake_client).sort
  end

  test "valid callback signs in the identity linked to the verified Xero subject" do
    identity = identity_with_xero_credential
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_session_url
      stub_completed_authorization(authorization_result)

      assert_no_difference -> { Identity.count } do
        assert_no_difference -> { ExternalIdentity.count } do
          assert_no_difference -> { Account.count } do
            assert_difference -> { identity.sessions.count }, 1 do
              get xero_session_callback_url, params: {
                code: "auth-code",
                state: fake_client.state
              }
            end
          end
        end
      end
    end

    assert cookies[:session_token].present?
    assert_redirected_to root_url
  end

  test "known Xero subject wins over a changed email claim" do
    identity = identity_with_xero_credential
    fake_client = FakeXeroClient.new
    changed_email_result = authorization_result(
      subject: "xero-user-123",
      email: "changed@example.com"
    )

    with_xero_client(fake_client) do
      get new_xero_session_url
      stub_completed_authorization(changed_email_result)

      assert_difference -> { identity.sessions.count }, 1 do
        get xero_session_callback_url, params: {
          code: "auth-code",
          state: fake_client.state
        }
      end
    end

    assert_equal "owner@example.com", identity.reload.email_address
    assert cookies[:session_token].present?
  end

  test "invalid state consumes the attempt before completing the Xero authorization" do
    identity_with_xero_credential
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_session_url
      Xero::Authorization.expects(:new).never

      assert_no_difference -> { Session.count } do
        get xero_session_callback_url, params: {
          code: "auth-code",
          state: "invalid-state"
        }
        get xero_session_callback_url, params: {
          code: "auth-code",
          state: fake_client.state
        }
      end
    end

    assert_not cookies[:session_token].present?
    assert_redirected_to new_session_url
  end

  test "an unknown Xero subject does not create or sign in an identity" do
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_session_url
      stub_completed_authorization(authorization_result(subject: "unknown-xero-user"))

      assert_no_identity_or_session_changes do
        get xero_session_callback_url, params: {
          code: "auth-code",
          state: fake_client.state
        }
      end
    end

    assert_not cookies[:session_token].present?
    assert_redirected_to new_session_url
  end

  test "an unknown Xero subject cannot sign in by matching an existing email" do
    identity_with_xero_credential(subject: "linked-xero-user")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_session_url
      stub_completed_authorization(
        authorization_result(subject: "different-xero-user", email: "owner@example.com")
      )

      assert_no_identity_or_session_changes do
        get xero_session_callback_url, params: {
          code: "auth-code",
          state: fake_client.state
        }
      end
    end

    assert_not cookies[:session_token].present?
    assert_redirected_to new_session_url
  end

  test "provider denial consumes the attempt without completing authorization" do
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_session_url
      Xero::Authorization.expects(:new).never

      assert_no_difference -> { Session.count } do
        get xero_session_callback_url, params: {
          error: "access_denied",
          state: fake_client.state
        }
        get xero_session_callback_url, params: {
          code: "auth-code",
          state: fake_client.state
        }
      end
    end

    assert_redirected_to new_session_url
  end

  test "token exchange failure consumes the attempt" do
    fake_client = FakeXeroClient.new
    authorization = mock("failed Xero authorization")
    authorization.expects(:complete!).once.raises(Xero::Authorization::Error, "invalid grant")

    with_xero_client(fake_client) do
      get new_xero_session_url
      Xero::Authorization.stubs(:new).returns(authorization)

      assert_no_difference -> { Session.count } do
        2.times do
          get xero_session_callback_url, params: {
            code: "auth-code",
            state: fake_client.state
          }
        end
      end
    end

    assert_redirected_to new_session_url
  end

  private
    def identity_with_xero_credential(subject: "xero-user-123")
      identity = Identity.create!(email_address: "owner@example.com")
      Account.create_with_owner(
        account: { name: "Acme Ltd" },
        owner: { name: "Owner Person", identity: identity }
      )
      identity.external_identities.create!(provider: :xero, subject: subject, email_address: identity.email_address)
      identity
    end

    def authorization_result(subject: "xero-user-123", email: "owner@example.com")
      Xero::Authorization::Result.new(
        identity: Xero::VerifiedIdentity.new(
          subject: subject,
          email: email,
          given_name: "Owner",
          family_name: "Person"
        ),
        token_set: {
          "access_token" => "identity-access-token",
          "id_token" => "identity-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email"
        },
        connections: [],
        authentication_event_id: nil
      )
    end

    def stub_completed_authorization(result)
      authorization = mock("completed Xero authorization")
      authorization.stubs(:complete!).returns(result)
      authorization.stubs(:complete).returns(result)
      authorization.stubs(:call).returns(result)
      Xero::Authorization.stubs(:new).returns(authorization)
    end

    def with_xero_client(fake_client)
      InvoiceSources::Xero::Configuration.any_instance.stubs(:configured?).returns(true)
      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)
      yield
    end

    def requested_scopes(fake_client)
      value = fake_client.authorization_options[:scopes] || fake_client.authorization_options[:scope]
      value.respond_to?(:to_ary) ? value.to_ary : value.to_s.split
    end

    def assert_no_identity_or_session_changes(&)
      assert_no_difference -> { Identity.count } do
        assert_no_difference -> { ExternalIdentity.count } do
          assert_no_difference -> { Account.count } do
            assert_no_difference -> { Session.count }, &
          end
        end
      end
    end

    class FakeXeroClient
      AUTHORIZATION_URL = "https://login.xero.com/identity/connect/authorize?fake=signin"

      attr_reader :authorization_options

      def authorization_url(**options)
        @authorization_options = options
        AUTHORIZATION_URL
      end

      def state
        authorization_options.fetch(:state)
      end
    end
end
