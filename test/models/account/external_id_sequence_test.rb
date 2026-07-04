require "test_helper"

class Account::ExternalIdSequenceTest < ActiveSupport::TestCase
  setup do
    Account::ExternalIdSequence.delete_all
  end

  test "generate sequential values" do
    first_value = Account::ExternalIdSequence.next
    second_value = Account::ExternalIdSequence.next
    third_value = Account::ExternalIdSequence.next

    assert_equal first_value + 1, second_value
    assert_equal second_value + 1, third_value
  end

  test "start from the maximum existing external account id" do
    max_id = Account.maximum(:external_account_id) || 0

    first_value = Account::ExternalIdSequence.next

    assert_equal max_id + 1, first_value
  end

  test "use a single record for the sequence" do
    3.times { Account::ExternalIdSequence.next }

    assert_equal 1, Account::ExternalIdSequence.count
  end

  test "#value creates the first record if it does not exist yet" do
    assert_nil Account::ExternalIdSequence.first

    value = nil
    assert_difference -> { Account::ExternalIdSequence.count }, 1 do
      value = Account::ExternalIdSequence.value
    end

    assert_not_nil value
    assert_equal value, Account::ExternalIdSequence.first.value
  end
end
