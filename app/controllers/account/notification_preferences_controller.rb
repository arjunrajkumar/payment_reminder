class Account::NotificationPreferencesController < ApplicationController
  def update
    NotificationSubscription.transaction do
      NotificationSubscription::EVENTS.each_key do |event|
        notification_user.notification_subscriptions
          .find_or_initialize_by(event:)
          .update!(email: email_enabled_for?(event))
      end
    end

    redirect_to account_settings_path(script_name: Current.account.slug),
      notice: "Notification preferences saved."
  end

  private
    def email_enabled_for?(event)
      ActiveModel::Type::Boolean.new.cast(notification_params[event]) || false
    end

    def notification_params
      @notification_params ||= params[:notifications]&.permit(*NotificationSubscription::EVENTS.keys) || {}
    end

    def notification_user
      @notification_user ||= Current.account.users.active.find_by!(identity: Current.identity)
    end
end
