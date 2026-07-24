require "monitor"

class EmailConnection::MailboxThreadLock
  TIMEOUT_SECONDS = 10
  POLL_INTERVAL_SECONDS = 0.01
  HELD_LOCKS_KEY = :email_connection_mailbox_thread_locks

  class Unavailable < EmailConnection::Errors::TemporaryProviderError; end

  class << self
    def synchronize(account:, provider_account_id:, provider_thread_id:)
      identity = [
        account.id,
        provider_account_id.to_s.strip.presence,
        provider_thread_id.to_s.strip.presence
      ]
      return yield if identity.any?(&:blank?)

      ActiveRecord::Base.connection_pool.with_connection do |connection|
        lock_name = lock_name_for(
          identity,
          namespace: connection.current_database
        )
        if held_lock?(lock_name)
          return with_held_lock(lock_name) { yield }
        end

        local_lock = checkout_local_lock(lock_name)
        local_lock_entered = false
        begin
          local_lock_entered = acquire_local_lock(local_lock)
          unless local_lock_entered
            raise Unavailable, "mailbox thread lock could not be acquired"
          end

          acquired = connection.uncached do
            connection.select_value(
              "SELECT GET_LOCK(" \
                "#{connection.quote(lock_name)}, #{TIMEOUT_SECONDS})"
            ).to_i == 1
          end
          raise Unavailable, "mailbox thread lock could not be acquired" unless acquired

          begin
            with_held_lock(lock_name) { yield }
          ensure
            connection.uncached do
              release_server_lock(connection, lock_name)
            end
          end
        ensure
          local_lock.exit if local_lock_entered
          checkin_local_lock(lock_name, local_lock)
        end
      end
    end

    private
      def checkout_local_lock(lock_name)
        local_locks_guard.synchronize do
          entry = local_locks[lock_name] ||= { lock: Monitor.new, users: 0 }
          entry[:users] += 1
          entry[:lock]
        end
      end

      def checkin_local_lock(lock_name, lock)
        local_locks_guard.synchronize do
          entry = local_locks.fetch(lock_name)
          entry[:users] -= 1
          local_locks.delete(lock_name) if entry[:users].zero? && entry[:lock] == lock
        end
      end

      def acquire_local_lock(lock)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT_SECONDS
        until lock.try_enter
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(POLL_INTERVAL_SECONDS)
        end
        true
      end

      def release_server_lock(connection, lock_name)
        connection_id = connection.select_value("SELECT CONNECTION_ID()").to_i
        loop do
          connection.select_value(
            "SELECT RELEASE_LOCK(#{connection.quote(lock_name)})"
          )
          owner_id = connection.select_value(
            "SELECT IS_USED_LOCK(#{connection.quote(lock_name)})"
          )
          break unless owner_id.to_i == connection_id
        end
      end

      def held_lock?(lock_name)
        held_locks.fetch(lock_name, 0).positive?
      end

      def with_held_lock(lock_name)
        held_locks[lock_name] = held_locks.fetch(lock_name, 0) + 1
        yield
      ensure
        remaining = held_locks.fetch(lock_name) - 1
        if remaining.zero?
          held_locks.delete(lock_name)
          Thread.current.thread_variable_set(HELD_LOCKS_KEY, nil) if
            held_locks.empty?
        else
          held_locks[lock_name] = remaining
        end
      end

      def held_locks
        Thread.current.thread_variable_get(HELD_LOCKS_KEY) ||
          {}.tap do |locks|
            Thread.current.thread_variable_set(HELD_LOCKS_KEY, locks)
          end
      end

      def local_locks
        @local_locks ||= {}
      end

      def local_locks_guard
        @local_locks_guard ||= Mutex.new
      end

      def lock_name_for(identity, namespace:)
        account_id, provider_account_id, = identity
        digest = Digest::SHA256.hexdigest(
          [ namespace, account_id, provider_account_id ].join(":")
        )
        "payment-reminder:mailbox-thread:#{digest.first(24)}"
      end
  end
end
