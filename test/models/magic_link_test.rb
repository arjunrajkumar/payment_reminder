require "test_helper"

class MagicLinkTest < ActiveSupport::TestCase
  test "generates a six character code and expiration" do
    magic_link = Identity.create!(email_address: "person@example.com").magic_links.create!

    assert_equal 6, magic_link.code.length
    assert_in_delta 15.minutes.from_now, magic_link.expires_at, 2.seconds
  end

  test "consume finds active sanitized code and destroys it" do
    magic_link = Identity.create!(email_address: "person@example.com").magic_links.create!(code: "G79NYX")

    assert_equal magic_link, MagicLink.consume(" g79-nyx ")
    assert_not MagicLink.exists?(magic_link.id)
  end

  test "consume ignores expired codes" do
    magic_link = Identity.create!(email_address: "person@example.com").magic_links.create!(expires_at: 1.minute.ago)

    assert_nil MagicLink.consume(magic_link.code)
  end
end
