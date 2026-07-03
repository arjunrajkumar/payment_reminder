class XeroConnection < ApplicationRecord
  validates :access_token, :refresh_token, :token_type, :expires_at, presence: true

  def self.current
    order(created_at: :desc).first
  end

  def self.from_oauth!(code:)
    xero_client = Xero::OauthClient.new
    token_set = xero_client.exchange_code(code: code)
    connections = xero_client.connections(access_token: token_set.fetch("access_token"))
    userinfo = xero_client.userinfo(access_token: token_set.fetch("access_token"))

    primary_connection = connections.first || {}

    create!(
      xero_user_id: userinfo["xero_userid"] || userinfo["sub"],
      email: userinfo["email"],
      tenant_id: primary_connection["tenantId"],
      tenant_name: primary_connection["tenantName"],
      access_token: token_set.fetch("access_token"),
      refresh_token: token_set.fetch("refresh_token"),
      id_token: token_set["id_token"],
      token_type: token_set.fetch("token_type", "Bearer"),
      scopes: token_set["scope"].to_s.split,
      expires_at: Time.current + token_set.fetch("expires_in").to_i.seconds,
      connections: connections,
      raw_token_set: token_set,
      raw_userinfo: userinfo
    )
  end

  def expired?
    expires_at <= Time.current
  end
end
