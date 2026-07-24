module CollectionHolds
  class Error < StandardError; end
  class IdempotencyConflict < Error; end
  class InvalidTransition < Error; end
  class StaleControl < Error; end
end
