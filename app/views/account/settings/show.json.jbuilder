json.account do
  json.(@account, :id, :external_account_id, :name)
  json.slug @account.slug
  json.created_at @account.created_at.utc
  json.updated_at @account.updated_at.utc
end

json.users @users do |user|
  json.(user, :id, :name, :role, :active)
  json.email_address user.identity&.email_address
  json.verified_at user.verified_at&.utc
  json.created_at user.created_at.utc
  json.updated_at user.updated_at.utc
end
