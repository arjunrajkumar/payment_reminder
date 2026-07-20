require "test_helper"

class Xero::JwksTest < ActiveSupport::TestCase
  test "caches signing keys and refreshes them when the verifier invalidates its key set" do
    client = FakeClient.new
    loader = Xero::Jwks.new(client:, cache: ActiveSupport::Cache::MemoryStore.new)

    assert_equal "key-1", loader.call.fetch("keys").sole.fetch("kid")
    assert_equal "key-1", loader.call.fetch("keys").sole.fetch("kid")
    assert_equal "key-2", loader.call(invalidate: true).fetch("keys").sole.fetch("kid")
    assert_equal 2, client.calls
  end

  private
    class FakeClient
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def jwks
        @calls += 1
        { "keys" => [ { "kid" => "key-#{calls}" } ] }
      end
    end
end
