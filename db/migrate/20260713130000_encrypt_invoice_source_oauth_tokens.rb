class EncryptInvoiceSourceOauthTokens < ActiveRecord::Migration[8.0]
  SENSITIVE_TOKEN_KEYS = %w[access_token refresh_token id_token client_secret].freeze

  class PlaintextInvoiceSource < ActiveRecord::Base
    self.table_name = "invoice_sources"
  end

  class EncryptedInvoiceSource < ActiveRecord::Base
    self.table_name = "invoice_sources"

    encrypts :access_token, :refresh_token
  end

  def up
    PlaintextInvoiceSource.find_each do |source|
      attributes = {
        raw_token_data: source.raw_token_data.to_h.stringify_keys.except(*SENSITIVE_TOKEN_KEYS)
      }
      attributes[:access_token] = source.access_token if source.access_token.present?
      attributes[:refresh_token] = source.refresh_token if source.refresh_token.present?

      EncryptedInvoiceSource.where(id: source.id).update_all(attributes)
    end
  end

  def down
    EncryptedInvoiceSource.find_each do |source|
      PlaintextInvoiceSource.where(id: source.id).update_all(
        access_token: source.access_token,
        refresh_token: source.refresh_token
      )
    end
  end
end
