class Receivables::AccountLock
  class Unavailable < EmailConnection::Errors::TemporaryProviderError; end

  def self.synchronize(account:)
    Account.transaction(requires_new: true) do
      Account.lock.find(account.id)
      yield
    end
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => error
    raise Unavailable.new("receivables account lock could not be acquired"),
      cause: error
  end
end
