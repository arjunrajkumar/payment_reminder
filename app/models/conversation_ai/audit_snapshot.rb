class ConversationAi::AuditSnapshot
  MAXIMUM_BYTES = 64.kilobytes

  class << self
    def bounded(value)
      json = JSON.generate(value)
      return value if json.bytesize <= MAXIMUM_BYTES

      {
        "truncated" => true,
        "sha256" => Digest::SHA256.hexdigest(json),
        "preview" => json.byteslice(0, MAXIMUM_BYTES - 512)
      }
    rescue JSON::GeneratorError
      { "unserializable" => true }
    end

    def retry_after(headers)
      value = headers["retry-after"].to_s
      return value.to_i.clamp(0, 86_400) if value.match?(/\A\d+\z/)

      [ (Time.httpdate(value) - Time.current).ceil, 0 ].max.clamp(0, 86_400)
    rescue ArgumentError
      nil
    end
  end
end
