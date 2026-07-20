require "test_helper"

class XeroSignupsControllerTest < ActionDispatch::IntegrationTest
  test "start is public and requests the Xero signup scopes with state and nonce" do
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_signup_url
    end

    assert_redirected_to FakeXeroClient::AUTHORIZATION_URL
    assert fake_client.authorization_options.fetch(:state).present?
    assert fake_client.authorization_options.fetch(:nonce).present?
    assert_equal InvoiceSources::Xero::Configuration.new.signup_redirect_uri,
      fake_client.authorization_options.fetch(:redirect_uri)

    scopes = requested_scopes(fake_client)
    assert_includes scopes, "openid"
    assert_includes scopes, "profile"
    assert_includes scopes, "email"
    assert_includes scopes, "accounting.invoices.read"
    assert_includes scopes, "accounting.contacts.read"
    assert_includes scopes, "offline_access"
  end

  test "valid callback provisions a Xero account and starts a PaymentReminder session" do
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_signup_url
      stub_completed_authorization(authorization_result)

      assert_difference -> { Identity.count }, 1 do
        assert_difference -> { ExternalIdentity.count }, 1 do
          assert_difference -> { Account.count }, 1 do
            assert_difference -> { User.count }, 2 do
              assert_difference -> { InvoiceSource.count }, 1 do
                assert_difference -> { Session.count }, 1 do
                  assert_enqueued_with(job: InvoiceSources::RefreshJob) do
                    get xero_signup_callback_url, params: {
                      code: "auth-code",
                      state: fake_client.state
                    }
                  end
                end
              end
            end
          end
        end
      end
    end

    external_identity = ExternalIdentity.find_by!(provider: :xero, subject: "xero-user-123")
    account = external_identity.identity.accounts.sole
    invoice_source = account.invoice_sources.xero.sole

    assert_equal "owner@example.com", external_identity.identity.email_address
    assert_equal "Acme Ltd", account.name
    assert_equal "Owner Person", account.users.owner.sole.name
    assert_equal "tenant-123", invoice_source.external_account_id
    assert_predicate invoice_source, :connected?
    assert cookies[:session_token].present?
    assert_redirected_to account_settings_url(script_name: account.slug)
  end

  test "invalid state fails before completing the Xero authorization" do
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_signup_url
      Xero::Authorization.expects(:new).never

      assert_no_signup_records_created do
        get xero_signup_callback_url, params: {
          code: "auth-code",
          state: "invalid-state"
        }
      end
    end

    assert_not cookies[:session_token].present?
    assert_redirected_to new_signup_url
  end

  test "an existing email with a different Xero subject fails closed" do
    Identity.create!(email_address: "owner@example.com")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_signup_url
      stub_completed_authorization(authorization_result)

      assert_no_difference -> { Identity.count } do
        assert_no_difference -> { ExternalIdentity.count } do
          assert_no_difference -> { Account.count } do
            assert_no_difference -> { InvoiceSource.count } do
              assert_no_difference -> { MagicLink.count } do
                get xero_signup_callback_url, params: {
                  code: "auth-code",
                  state: fake_client.state
                }
              end
            end
          end
        end
      end
    end

    assert_not cookies[:session_token].present?
    assert_redirected_to new_session_url
  end

  test "an invoice refresh enqueue failure does not fail completed signup" do
    fake_client = FakeXeroClient.new
    enqueue_error = ActiveJob::EnqueueError.new("queue unavailable")

    with_xero_client(fake_client) do
      get new_xero_signup_url
      stub_completed_authorization(authorization_result)
      InvoiceSources::RefreshJob.stubs(:perform_later).raises(enqueue_error)
      Rails.error.expects(:report).with(enqueue_error, severity: :error)

      assert_difference -> { Identity.count }, 1 do
        assert_difference -> { Account.count }, 1 do
          assert_difference -> { Session.count }, 1 do
            get xero_signup_callback_url, params: {
              code: "auth-code",
              state: fake_client.state
            }
          end
        end
      end
    end

    account = Identity.find_by!(email_address: "owner@example.com").accounts.sole
    assert_redirected_to account_settings_url(script_name: account.slug)
  end

  private
    def authorization_result
      Xero::Authorization::Result.new(
        identity: Xero::VerifiedIdentity.new(
          subject: "xero-user-123",
          email: "owner@example.com",
          given_name: "Owner",
          family_name: "Person"
        ),
        token_set: {
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        },
        connections: [
          {
            "id" => "connection-123",
            "authEventId" => "auth-event-123",
            "tenantId" => "tenant-123",
            "tenantType" => "ORGANISATION",
            "tenantName" => "Acme Ltd"
          }
        ],
        authentication_event_id: "auth-event-123"
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

    def assert_no_signup_records_created(&)
      assert_no_difference -> { Identity.count } do
        assert_no_difference -> { ExternalIdentity.count } do
          assert_no_difference -> { Account.count } do
            assert_no_difference -> { InvoiceSource.count }, &
          end
        end
      end
    end

    class FakeXeroClient
      AUTHORIZATION_URL = "https://login.xero.com/identity/connect/authorize?fake=signup"

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
