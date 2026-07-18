class PagesController < ApplicationController
  allow_unauthenticated_access
  disallow_account_scope

  layout "public"

  def privacy
    @page_title = "Privacy Policy"
    @body_class = "legal-document"
  end

  def terms
    @page_title = "Terms of Service"
    @body_class = "legal-document"
  end
end
