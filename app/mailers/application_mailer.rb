class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM_ADDRESS", "PaidJar <support@paidjar.com>")

  layout "mailer"
  append_view_path Rails.root.join("app/views/mailers")
end
