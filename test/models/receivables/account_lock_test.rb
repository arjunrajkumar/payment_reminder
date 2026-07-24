require "test_helper"
require "timeout"

class Receivables::AccountLockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account_id = Thread.new do
      Account.create!(name: "Receivables coordination").id
    end.value
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value
  end

  test "serializes database work for one receivables account" do
    first_entered = Queue.new
    release_first = Queue.new
    second_attempting = Queue.new
    second_entered = Queue.new

    first = Thread.new do
      Receivables::AccountLock.synchronize(account: Account.find(@account_id)) do
        first_entered << true
        release_first.pop
      end
    end
    Timeout.timeout(2) { first_entered.pop }

    second = Thread.new do
      second_attempting << true
      Receivables::AccountLock.synchronize(account: Account.find(@account_id)) do
        second_entered << true
      end
    end
    Timeout.timeout(2) { second_attempting.pop }

    assert_raises(ThreadError) { second_entered.pop(true) }
    release_first << true
    Timeout.timeout(2) { second_entered.pop }
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end
end
