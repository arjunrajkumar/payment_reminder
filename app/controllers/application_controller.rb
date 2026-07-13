class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  include CurrentTimezone
  include RequestForgeryProtection

  etag { "v1" }
  stale_when_importmap_changes

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
end
