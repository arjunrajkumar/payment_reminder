require "test_helper"

class Account::ConversationAiSettingsControllerTest <
    ActionDispatch::IntegrationTest
  test "administrator enables a configured provider and settings show health" do
    account = sign_up_and_complete
    ConversationAi::ProviderRegistry.stubs(:configured).returns([ "openai" ])

    patch account_conversation_ai_setting_url(script_name: account.slug),
      params: {
        conversation_ai_setting: {
          mode: "shadow",
          provider: "openai"
        }
      }

    assert_redirected_to account_settings_path(script_name: account.slug)
    assert_predicate account.reload, :conversation_ai_mode_shadow?
    assert_equal "openai", account.conversation_ai_provider

    get account_settings_url(script_name: account.slug)
    assert_response :success
    assert_select "[data-testid='conversation-ai-settings']" do
      assert_select "option[value='shadow'][selected]"
      assert_select "option[value='approval']", count: 0
      assert_select "a", "Open shadow evaluation report"
    end
  end

  test "member cannot change mode" do
    account = sign_up_and_complete(email_address: "member-ai-settings@example.com")
    account.users.owner.sole.update!(role: :member)
    ConversationAi::ProviderRegistry.stubs(:configured).returns([ "openai" ])

    patch account_conversation_ai_setting_url(script_name: account.slug),
      params: {
        conversation_ai_setting: {
          mode: "shadow",
          provider: "openai"
        }
      }

    assert_redirected_to root_url(script_name: nil)
    assert_predicate account.reload, :conversation_ai_mode_off?
  end

  test "unconfigured provider fails closed" do
    account = sign_up_and_complete(email_address: "unconfigured-ai@example.com")
    ConversationAi::ProviderRegistry.stubs(:configured).returns([])

    patch account_conversation_ai_setting_url(script_name: account.slug),
      params: {
        conversation_ai_setting: {
          mode: "shadow",
          provider: "anthropic"
        }
      }

    assert_redirected_to account_settings_path(script_name: account.slug)
    assert_match(/configured AI provider/, flash[:alert])
    assert_predicate account.reload, :conversation_ai_mode_off?
  end

  private
    def sign_up_and_complete(email_address: "owner-ai-settings@example.com")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url,
        params: { signup: { full_name: "AI Settings Owner" } }

      Identity.find_by!(email_address:).accounts.first
    end
end
