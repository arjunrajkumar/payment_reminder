module MagicLink::Code
  class << self
    def generate(length)
      SecureRandom.base36(length).upcase
    end

    def sanitize(code)
      if code.present?
        normalize_code(code)
          .then { remove_invalid_characters(it) }
      end
    end

    private
      def normalize_code(code)
        code.to_s.upcase
      end

      def remove_invalid_characters(code)
        code.gsub(/[^0-9A-Z]/, "")
      end
  end
end
