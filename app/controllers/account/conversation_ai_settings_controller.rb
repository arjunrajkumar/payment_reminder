class Account::ConversationAiSettingsController < ApplicationController
  require_account_admin

  def update
    ConversationAi::SettingChange.call(
      account: Current.account,
      actor_user: Current.user,
      actor_identity: Current.identity,
      mode: setting_params.fetch(:mode),
      provider: setting_params[:provider]
    )
    redirect_to account_settings_path, notice: "AI shadow settings saved."
  rescue ConversationAi::Configuration::Error, ArgumentError => error
    redirect_to account_settings_path, alert: error.message
  end

  private
    def setting_params
      params.expect(conversation_ai_setting: %i[mode provider])
    end
end
