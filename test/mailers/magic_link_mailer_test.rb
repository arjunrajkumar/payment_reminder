require "test_helper"

class MagicLinkMailerTest < ActionMailer::TestCase
  test "signup code email uses welcome copy" do
    identity = Identity.create!(email_address: "person@example.com")
    magic_link = identity.magic_links.create!(purpose: :sign_up, code: "G79NYX")

    mail = MagicLinkMailer.sign_in_instructions(magic_link)

    assert_equal [ "person@example.com" ], mail.to
    assert_equal "Your PaidJar code is G79NYX", mail.subject
    assert_match "Welcome to PaidJar!", mail.text_part.body.to_s
    assert_match "G79NYX", mail.text_part.body.to_s
  end
end
