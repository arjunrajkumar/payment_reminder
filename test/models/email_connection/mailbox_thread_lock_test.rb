require "test_helper"
require "timeout"

class EmailConnection::MailboxThreadLockTest < ActiveSupport::TestCase
  test "serializes work for the same account mailbox and Gmail thread" do
    account = accounts(:paid_jar)
    connection = email_connections(:paid_jar_gmail)
    first_entered = Queue.new
    release_first = Queue.new
    second_entered = Queue.new

    first = Thread.new do
      EmailConnection::MailboxThreadLock.synchronize(
        account:,
        provider_account_id: connection.provider_account_id,
        provider_thread_id: "serialized-thread"
      ) do
        first_entered << true
        release_first.pop
      end
    end
    Timeout.timeout(2) { first_entered.pop }
    second = Thread.new do
      EmailConnection::MailboxThreadLock.synchronize(
        account:,
        provider_account_id: connection.provider_account_id,
        provider_thread_id: "serialized-thread"
      ) do
        second_entered << true
      end
    end

    assert_raises(ThreadError) { second_entered.pop(true) }
    release_first << true
    Timeout.timeout(2) { second_entered.pop }
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end

  test "checks local registry entries back in after repeated acquisition timeouts" do
    account = accounts(:paid_jar)
    connection = email_connections(:paid_jar_gmail)
    lock_class = EmailConnection::MailboxThreadLock
    lock_class.stubs(:acquire_local_lock).returns(false)

    3.times do
      assert_raises EmailConnection::MailboxThreadLock::Unavailable do
        lock_class.synchronize(
          account:,
          provider_account_id: connection.provider_account_id,
          provider_thread_id: "timed-out-thread"
        ) { flunk "timed-out lock must not enter its block" }
      end
    end

    assert_empty lock_class.send(:local_locks)
  end

  test "namespaces server-global advisory locks by database" do
    lock_class = EmailConnection::MailboxThreadLock
    identity = [ accounts(:paid_jar).id, "provider", "thread" ]

    first = lock_class.send(
      :lock_name_for,
      identity,
      namespace: "paid_jar_test-0"
    )
    second = lock_class.send(
      :lock_name_for,
      identity,
      namespace: "paid_jar_test-1"
    )

    assert_not_equal first, second
  end

  test "one mailbox uses one lock across every Gmail thread" do
    lock_class = EmailConnection::MailboxThreadLock
    account_id = accounts(:paid_jar).id
    provider_account_id = email_connections(:paid_jar_gmail)
      .provider_account_id

    first = lock_class.send(
      :lock_name_for,
      [ account_id, provider_account_id, "a-thread" ],
      namespace: "paid_jar_test"
    )
    second = lock_class.send(
      :lock_name_for,
      [ account_id, provider_account_id, "z-thread" ],
      namespace: "paid_jar_test"
    )
    other_mailbox = lock_class.send(
      :lock_name_for,
      [ account_id, "other-provider", "a-thread" ],
      namespace: "paid_jar_test"
    )

    assert_equal first, second
    assert_not_equal first, other_mailbox
  end

  test "opposite outer thread keys cannot deadlock nested reconciliation" do
    account = accounts(:paid_jar)
    provider_account_id = email_connections(:paid_jar_gmail)
      .provider_account_id
    first_outer_entered = Queue.new
    release_first = Queue.new
    completed = Queue.new

    first = Thread.new do
      synchronize(account:, provider_account_id:, thread_id: "z-thread") do
        first_outer_entered << true
        release_first.pop
        synchronize(account:, provider_account_id:, thread_id: "a-thread") do
          completed << :first
        end
      end
    rescue StandardError => error
      completed << error
    end
    Timeout.timeout(2) { first_outer_entered.pop }
    second = Thread.new do
      synchronize(account:, provider_account_id:, thread_id: "a-thread") do
        synchronize(account:, provider_account_id:, thread_id: "z-thread") do
          completed << :second
        end
      end
    rescue StandardError => error
      completed << error
    end

    release_first << true
    results = 2.times.map { Timeout.timeout(2) { completed.pop } }
    assert_equal %i[first second], results.sort
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end

  test "nested mailbox work acquires the server lock only once" do
    account = accounts(:paid_jar)
    provider_account_id = email_connections(:paid_jar_gmail)
      .provider_account_id
    lock_queries = []
    subscriber = lambda do |event|
      sql = event.payload[:sql]
      lock_queries << sql if sql.match?(/(?:GET|RELEASE)_LOCK/)
    end

    ActiveSupport::Notifications.subscribed(
      subscriber,
      "sql.active_record"
    ) do
      synchronize(account:, provider_account_id:, thread_id: "outer") do
        ActiveSupport::IsolatedExecutionState.clear
        synchronize(account:, provider_account_id:, thread_id: "inner") do
          assert true
        end
      end
    end

    assert_equal 1, lock_queries.count { _1.include?("GET_LOCK") }
    assert_equal 1, lock_queries.count { _1.include?("RELEASE_LOCK") }
  end

  test "outer cleanup releases any reentrant server lock count" do
    account = accounts(:paid_jar)
    provider_account_id = email_connections(:paid_jar_gmail)
      .provider_account_id
    connection = ActiveRecord::Base.connection
    identity = [ account.id, provider_account_id, "thread" ]
    lock_name = EmailConnection::MailboxThreadLock.send(
      :lock_name_for,
      identity,
      namespace: connection.current_database
    )

    synchronize(account:, provider_account_id:, thread_id: "thread") do
      connection.uncached do
        assert_equal 1, connection.select_value(
          "SELECT GET_LOCK(#{connection.quote(lock_name)}, 0)"
        ).to_i
      end
    end

    connection.uncached do
      assert_equal 1, connection.select_value(
        "SELECT IS_FREE_LOCK(#{connection.quote(lock_name)})"
      ).to_i
    end
  ensure
    if connection && lock_name
      connection.select_value("SELECT RELEASE_ALL_LOCKS()")
    end
  end

  private
    def synchronize(account:, provider_account_id:, thread_id:, &block)
      EmailConnection::MailboxThreadLock.synchronize(
        account:,
        provider_account_id:,
        provider_thread_id: thread_id,
        &block
      )
    end
end
