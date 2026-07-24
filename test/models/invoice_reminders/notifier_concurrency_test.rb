require "test_helper"
require "net/smtp"
require "timeout"

class InvoiceReminders::NotifierConcurrencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  FakeDelivery = Data.define(:callback) do
    def deliver_now
      callback.call
    end
  end
  RenderedDelivery = Data.define(:render_callback, :delivery_callback) do
    def message
      self
    end

    def encoded
      render_callback.call
    end

    def deliver_now
      delivery_callback.call
    end
  end

  setup do
    @account_id, @reminder_id, @outcome_id = Thread.new { create_records }.value
    clear_enqueued_jobs
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value if account_id
  end

  test "a second caller skips an active successful delivery claim" do
    started = Queue.new
    release = Queue.new
    calls = 0
    delivery = FakeDelivery.new(lambda do
      calls += 1
      started << true
      release.pop
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)

    first = run_delivery_in_thread
    Timeout.timeout(2) { started.pop }

    second_result = deliver_outcome
    assert_equal :busy, second_result
    assert_empty ConversationEvent.kind_invoice_reminder_notifications_finalized

    release << true
    assert_equal :delivered, Timeout.timeout(5) { first.value }
    assert_equal 1, calls
    assert_predicate outcome.reload, :status_delivered?
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "a second caller does not freeze an active known failure as uncertain" do
    started = Queue.new
    release = Queue.new
    calls = 0
    failed_delivery = FakeDelivery.new(lambda do
      calls += 1
      started << true
      release.pop
      raise Net::SMTPServerBusy, "451 provider rejected before acceptance"
    end)
    successful_delivery = FakeDelivery.new(-> { calls += 1 })
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(failed_delivery, successful_delivery)
    Rails.logger.stubs(:error)

    first = run_delivery_in_thread
    Timeout.timeout(2) { started.pop }

    assert_equal :busy, deliver_outcome
    assert_predicate outcome.reload, :status_delivering?

    release << true
    assert_equal :retry, Timeout.timeout(5) { first.value }
    assert_predicate outcome.reload, :status_pending?
    assert_empty ConversationEvent.kind_invoice_reminder_notifications_finalized

    assert_equal :delivered, deliver_outcome
    assert_equal 2, calls
    assert_predicate outcome.reload, :status_delivered?
  end

  test "concurrent sweeps enqueue only one owned retry" do
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
        end
      end
    end
    threads.each do |thread|
      Timeout.timeout(5) { thread.value }
    end

    jobs = enqueued_jobs.select do |job|
      job.fetch(:job) == InvoiceReminders::NotificationDeliveryJob &&
        job.fetch(:args) == [ @outcome_id ]
    end
    assert_equal 1, jobs.size
    assert_equal jobs.sole.fetch("job_id"), outcome.reload.retry_job_id
  end

  test "concurrent terminal audit repair writes once and never resends" do
    outcome.update!(
      status: :delivered,
      delivered_at: Time.current,
      attempts: 1
    )
    InvoiceReminderNotificationMailer.expects(:reminder_sent).never

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
        end
      end
    end
    threads.each do |thread|
      Timeout.timeout(5) { thread.value }
    end

    assert_equal 1, ConversationEvent
      .kind_invoice_reminder_notifications_finalized
      .where(conversation_message_id: reminder.conversation_message_id)
      .count
    assert reminder.reload.notifications_finalized_at
    assert_predicate outcome.reload, :status_delivered?
  end

  test "six slow builders retain one owner without false exhaustion" do
    render_started = Queue.new
    release_render = Queue.new
    sends = Queue.new
    delivery = RenderedDelivery.new(
      -> {
        render_started << true
        release_render.pop
      },
      -> { sends << true }
    )
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    results = Queue.new
    threads = 6.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << deliver_outcome
        end
      rescue StandardError => error
        results << error
      end
    end

    Timeout.timeout(2) { render_started.pop }
    contenders = 5.times.map { Timeout.timeout(2) { results.pop } }
    assert_equal [ :busy ] * 5, contenders.sort
    assert_equal 0, outcome.reload.build_attempts
    assert outcome.build_token

    release_render << true
    assert_equal :delivered, Timeout.timeout(5) { results.pop }
    threads.each do |thread|
      Timeout.timeout(5) { thread.join }
    end

    assert_equal 1, sends.size
    assert_predicate outcome.reload, :status_delivered?
    assert_equal 0, outcome.build_attempts
    assert_equal 1, outcome.attempts
  ensure
    6.times { release_render << true } if release_render
    threads&.each(&:join)
  end

  private
    def outcome
      InvoiceReminderNotificationDelivery.find(@outcome_id)
    end

    def reminder
      InvoiceReminder.find(@reminder_id)
    end

    def deliver_outcome
      InvoiceReminders::Notifier.deliver_outcome(
        outcome,
        schedule_retry: false
      )
    end

    def run_delivery_in_thread
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { deliver_outcome }
      end
    end

    def create_records
      account = Account.create!(name: "Notification concurrency")
      identity = Identity.create!(
        email_address: "notification-concurrency-#{SecureRandom.hex(5)}@example.com"
      )
      user = account.users.create!(
        name: "Notification concurrency",
        identity:,
        verified_at: Time.current
      )
      user.notification_subscriptions.create!(
        event: :invoice_reminder,
        email: true
      )
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = source.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "Notification concurrency customer"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        status: :open,
        amount_due: 100
      )
      message = invoice.conversation_messages.create!(
        account:,
        conversation: Conversation.for_invoice!(invoice:),
        direction: :outbound,
        kind: :scheduled_reminder,
        status: :sent,
        sent_at: Time.current
      )
      reminder = invoice.invoice_reminders.create!(
        account:,
        conversation_message: message,
        category: :pre_due,
        day_offset: 7,
        stage_key: "pre_due_7",
        tone: :friendly,
        terminal_at_delivery: false,
        notifications_initialized_at: Time.current
      )
      outcome = reminder.notification_deliveries.create!(
        account:,
        recipient_user: user,
        recipient_user_snapshot_id: user.id,
        recipient_email: identity.email_address,
        event_name: InvoiceReminders::Notifier::EVENTS.fetch(:reminder)
      )
      [ account.id, reminder.id, outcome.id ]
    end
end
