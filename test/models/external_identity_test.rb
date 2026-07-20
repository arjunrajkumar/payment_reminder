require "test_helper"

class ExternalIdentityTest < ActiveSupport::TestCase
  test "belongs to the canonical identity" do
    identity = Identity.create!(email_address: "owner@example.com")
    external_identity = identity.external_identities.create!(
      provider: :xero,
      subject: "xero-user-123",
      email_address: "Owner@Example.com"
    )

    assert_equal identity, external_identity.identity
    assert_equal "xero", external_identity.provider
    assert_equal "xero-user-123", external_identity.subject
    assert_equal "owner@example.com", external_identity.email_address
  end

  test "provider subject identifies exactly one identity" do
    first_identity = Identity.create!(email_address: "first@example.com")
    second_identity = Identity.create!(email_address: "second@example.com")
    first_identity.external_identities.create!(provider: :xero, subject: "xero-user-123")

    duplicate = second_identity.external_identities.build(provider: :xero, subject: "xero-user-123")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:subject], "has already been taken"
  end

  test "provider subject uniqueness is enforced by the database" do
    first_identity = Identity.create!(email_address: "first@example.com")
    second_identity = Identity.create!(email_address: "second@example.com")
    first_identity.external_identities.create!(provider: :xero, subject: "xero-user-123")
    duplicate = second_identity.external_identities.build(provider: :xero, subject: "xero-user-123")

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "provider subjects are case-sensitive opaque identifiers" do
    first_identity = Identity.create!(email_address: "first@example.com")
    second_identity = Identity.create!(email_address: "second@example.com")

    first_identity.external_identities.create!(provider: :xero, subject: "CaseSensitiveSubject")
    credential = second_identity.external_identities.create!(provider: :xero, subject: "casesensitivesubject")

    assert_equal "casesensitivesubject", credential.subject
  end

  test "an identity can link only one credential for a provider" do
    identity = Identity.create!(email_address: "owner@example.com")
    identity.external_identities.create!(provider: :xero, subject: "xero-user-123")

    duplicate = identity.external_identities.build(provider: :xero, subject: "xero-user-456")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:provider], "has already been taken"
  end

  test "provider and subject cannot be changed after linking" do
    identity = Identity.create!(email_address: "owner@example.com")
    external_identity = identity.external_identities.create!(provider: :xero, subject: "xero-user-123")

    external_identity.subject = "different-user"

    assert_not external_identity.valid?
    assert_includes external_identity.errors[:subject], "cannot be changed"
  end

  test "destroying an identity removes its external credentials" do
    identity = Identity.create!(email_address: "owner@example.com")
    external_identity = identity.external_identities.create!(provider: :xero, subject: "xero-user-123")

    identity.destroy!

    assert_not ExternalIdentity.exists?(external_identity.id)
  end
end
