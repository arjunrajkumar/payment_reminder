module Xero
  class Signup
    class Error < StandardError; end
    class ExistingIdentityError < Error; end
    class ConnectionError < Error; end
    class TenantConflictError < Error; end

    Result = Data.define(:identity, :account, :invoice_source, :new_account)

    def initialize(authorization:)
      @authorization = authorization
    end

    def complete!
      connection = sole_organization_connection!
      email_address = verified_email_address!
      validate_accounting_token_set!

      if external_identity = ExternalIdentity.xero.find_by(subject: authorization.identity.subject)
        reconnect_existing!(external_identity:, connection:, email_address:)
      else
        create_account!(connection:, email_address:)
      end
    rescue ActiveRecord::RecordNotUnique
      if Identity.exists?(email_address: email_address)
        raise ExistingIdentityError, existing_identity_message
      else
        raise TenantConflictError, tenant_conflict_message
      end
    end

    private
      attr_reader :authorization

      def sole_organization_connection!
        connections = Array(authorization.connections).select do |connection|
          connection["tenantType"].to_s.casecmp?("ORGANISATION")
        end

        unless connections.one?
          raise ConnectionError, "Choose exactly one Xero organization when you approve access."
        end

        connections.sole.tap do |connection|
          %w[id tenantId tenantName].each { |key| connection.fetch(key) }
        end
      rescue KeyError
        raise ConnectionError, "Xero did not return a complete organization connection."
      end

      def verified_email_address!
        email_address = authorization.identity.email.to_s.strip.downcase.presence
        valid = email_address.present? && URI::MailTo::EMAIL_REGEXP.match?(email_address)
        raise ConnectionError, "Xero did not return a valid email address." unless valid

        email_address
      end

      def validate_accounting_token_set!
        %w[access_token refresh_token expires_in].each do |key|
          value = authorization.token_set.fetch(key)
          raise KeyError if value.blank?
        end
      rescue KeyError
        raise ConnectionError, "Xero did not return the credentials needed to sync invoices."
      end

      def create_account!(connection:, email_address:)
        if Identity.exists?(email_address:)
          raise ExistingIdentityError, existing_identity_message
        end

        identity = account = invoice_source = nil

        ApplicationRecord.transaction do
          identity = Identity.create!(email_address:)
          identity.external_identities.create!(
            provider: :xero,
            subject: authorization.identity.subject,
            email_address:
          )
          account = Account.create_with_owner(
            account: { name: connection.fetch("tenantName") },
            owner: { name: authorization.identity.name, identity: }
          )
          invoice_source = connect_source!(account:, connection:)
        end

        Result.new(identity:, account:, invoice_source:, new_account: true)
      end

      def reconnect_existing!(external_identity:, connection:, email_address:)
        identity = external_identity.identity
        account = account_for_existing_identity!(identity, connection.fetch("tenantId"))
        invoice_source = nil

        ApplicationRecord.transaction do
          external_identity.update!(email_address:)
          invoice_source = connect_source!(account:, connection:)
        end

        Result.new(identity:, account:, invoice_source:, new_account: false)
      end

      def account_for_existing_identity!(identity, tenant_id)
        if source = InvoiceSource.xero.find_by(external_account_id: tenant_id)
          return source.account if identity.users.active.exists?(account_id: source.account_id)

          raise TenantConflictError, tenant_conflict_message
        end

        accounts = identity.users.active.includes(:account).map(&:account).uniq
        return accounts.sole if accounts.one?

        raise ConnectionError, "Sign in by email and connect Xero from the account you want to use."
      end

      def connect_source!(account:, connection:)
        source = account.invoice_sources.find_or_initialize_by(provider: :xero)
        if source.persisted? && source.external_account_id != connection.fetch("tenantId")
          raise ConnectionError, "This account is already connected to a different Xero organization."
        end

        InvoiceSources::Xero.new(source).connect_from_authorization!(
          token_set: authorization.token_set,
          connection:,
          identity: authorization.identity,
          authentication_event_id: authorization.authentication_event_id
        )
      rescue ActiveRecord::RecordInvalid => error
        if error.record.is_a?(InvoiceSource) && error.record.errors.of_kind?(:external_account_id, :taken)
          raise TenantConflictError, tenant_conflict_message
        end

        raise
      end

      def existing_identity_message
        "An account already uses this email address. Sign in by email to continue with that account."
      end

      def tenant_conflict_message
        "That Xero organization is already connected to another account."
      end
  end
end
