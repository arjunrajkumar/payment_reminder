module ConversationActions::Commands
  class Unsafe < ConversationActions::Error; end
  class Stale < Unsafe; end
  class Unauthorized < Unsafe; end
end
