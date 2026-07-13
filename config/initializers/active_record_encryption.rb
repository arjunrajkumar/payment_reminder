key_generator = Rails.application.key_generator
encryption_config = Rails.application.config.active_record.encryption

encryption_config.primary_key = key_generator.generate_key("active_record_encryption/primary_key", 32)
encryption_config.deterministic_key = key_generator.generate_key("active_record_encryption/deterministic_key", 32)
encryption_config.key_derivation_salt = key_generator.generate_key("active_record_encryption/key_derivation_salt", 32)
encryption_config.encrypt_fixtures = true if Rails.env.test?
