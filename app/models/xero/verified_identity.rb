module Xero
  VerifiedIdentity = Data.define(:subject, :email, :given_name, :family_name) do
    def name
      [ given_name, family_name ].compact_blank.join(" ").presence || email.to_s.split("@", 2).first
    end
  end
end
