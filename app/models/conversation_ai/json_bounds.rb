module ConversationAi::JsonBounds
  extend ActiveSupport::Concern

  class_methods do
    def validates_json_bytes(*attributes, maximum:)
      validates_each(*attributes) do |record, attribute, value|
        bytes = JSON.generate(value).bytesize
        if bytes > maximum
          record.errors.add(
            attribute,
            "must be no larger than #{maximum} bytes"
          )
        end
      rescue JSON::GeneratorError
        record.errors.add(attribute, "must be valid JSON")
      end
    end
  end
end
