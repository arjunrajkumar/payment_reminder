class OutboundEmailConnection::Delivery
  def initialize(account:, connection:)
    @account = account
    @connection = connection
  end

  def deliver(mail_message)
    provider_delivery.deliver(mail_message)
  end

  private
    attr_reader :account, :connection

    def provider_delivery
      provider_delivery_class.new(account:, connection:)
    end

    def provider_delivery_class
      "OutboundEmailConnection::#{connection.provider.classify}::Delivery".constantize
    end
end
