class ConversationAi::ActorSnapshot
  class << self
    def for(user)
      {
        "id" => user.id,
        "name" => user.name,
        "role" => user.role,
        "email" => user.identity&.email_address
      }.compact
    end
  end
end
