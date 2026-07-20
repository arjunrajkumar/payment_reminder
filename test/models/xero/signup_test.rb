require "test_helper"

class Xero::SignupTest < ActiveSupport::TestCase
  setup do
    @authorization = Xero::Authorization::Result.new(
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

  test "creates an identity account owner and connected Xero source" do
    assert_difference -> { Identity.count }, 1 do
      assert_difference -> { ExternalIdentity.count }, 1 do
        assert_difference -> { Account.count }, 1 do
          assert_difference -> { User.count }, 2 do
            assert_difference -> { InvoiceSource.count }, 1 do
              @result = Xero::Signup.new(authorization: @authorization).complete!
            end
          end
        end
      end
    end

    assert_equal "owner@example.com", @result.identity.email_address
    assert_equal "xero-user-123", @result.identity.external_identities.xero.sole.subject
    assert_equal "Acme Ltd", @result.account.name
    assert_equal "Owner Person", @result.account.users.owner.sole.name
    assert_predicate @result.invoice_source, :connected?
    assert_equal "tenant-123", @result.invoice_source.external_account_id
    assert_equal "connection-123", @result.invoice_source.provider_data.fetch("connection_id")
  end

  test "does not silently merge a new Xero subject into an email identity" do
    Identity.create!(email_address: "owner@example.com")

    assert_no_difference -> { ExternalIdentity.count } do
      assert_no_difference -> { Account.count } do
        assert_raises Xero::Signup::ExistingIdentityError do
          Xero::Signup.new(authorization: @authorization).complete!
        end
      end
    end
  end

  test "requires exactly one organization connection" do
    authorization = @authorization.with(connections: [])

    assert_raises Xero::Signup::ConnectionError do
      Xero::Signup.new(authorization: authorization).complete!
    end
  end

  test "rejects more than one organization connection" do
    second_connection = @authorization.connections.sole.merge(
      "id" => "connection-456",
      "tenantId" => "tenant-456",
      "tenantName" => "Other Ltd"
    )
    authorization = @authorization.with(
      connections: @authorization.connections + [ second_connection ]
    )

    assert_raises Xero::Signup::ConnectionError do
      Xero::Signup.new(authorization:).complete!
    end
  end

  test "missing refresh credentials roll back signup" do
    authorization = @authorization.with(
      token_set: @authorization.token_set.except("refresh_token")
    )

    assert_no_difference [
      -> { Identity.count },
      -> { ExternalIdentity.count },
      -> { Account.count },
      -> { InvoiceSource.count }
    ] do
      assert_raises Xero::Signup::ConnectionError do
        Xero::Signup.new(authorization:).complete!
      end
    end
  end

  test "reuses the identity and account when the same Xero user signs up again" do
    first_result = Xero::Signup.new(authorization: @authorization).complete!
    refreshed_authorization = @authorization.with(
      token_set: @authorization.token_set.merge("access_token" => "new-access-token")
    )

    assert_no_difference [
      -> { Identity.count },
      -> { ExternalIdentity.count },
      -> { Account.count },
      -> { InvoiceSource.count }
    ] do
      @result = Xero::Signup.new(authorization: refreshed_authorization).complete!
    end

    assert_equal first_result.identity, @result.identity
    assert_equal first_result.account, @result.account
    assert_equal "new-access-token", @result.invoice_source.access_token
  end

  test "does not replace an existing source with a different Xero organization" do
    result = Xero::Signup.new(authorization: @authorization).complete!
    different_connection = @authorization.connections.sole.merge(
      "id" => "connection-456",
      "tenantId" => "tenant-456",
      "tenantName" => "Different Ltd"
    )
    authorization = @authorization.with(
      token_set: @authorization.token_set.merge("access_token" => "new-access-token"),
      connections: [ different_connection ]
    )

    assert_raises Xero::Signup::ConnectionError do
      Xero::Signup.new(authorization:).complete!
    end

    assert_equal "tenant-123", result.invoice_source.reload.external_account_id
    assert_equal "access-token", result.invoice_source.access_token
  end

  test "does not attach a Xero organization owned by another account" do
    other_account = Account.create!(name: "Other account")
    other_account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "tenant-123",
      external_account_name: "Acme Ltd",
      access_token: "other-access-token",
      refresh_token: "other-refresh-token"
    )

    assert_no_difference [
      -> { Identity.count },
      -> { ExternalIdentity.count },
      -> { Account.count }
    ] do
      assert_raises Xero::Signup::TenantConflictError do
        Xero::Signup.new(authorization: @authorization).complete!
      end
    end
  end

  test "does not reconnect an organization through an inactive membership" do
    result = Xero::Signup.new(authorization: @authorization).complete!
    result.account.users.owner.sole.deactivate

    assert_raises Xero::Signup::TenantConflictError do
      Xero::Signup.new(authorization: @authorization).complete!
    end

    assert_equal "access-token", result.invoice_source.reload.access_token
  end
end
