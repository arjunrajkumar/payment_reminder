Rails.application.routes.draw do
  root "landing#index"
  get "privacy", to: "pages#privacy", as: :privacy
  get "terms", to: "pages#terms", as: :terms

  get "signup/xero", to: "xero/signups#new", as: :new_xero_signup
  get "signup/xero/callback", to: "xero/signups#create", as: :xero_signup_callback
  get "session/xero", to: "xero/sessions#new", as: :new_xero_session
  get "session/xero/callback", to: "xero/sessions#create", as: :xero_session_callback

  resources :invoices, only: :index
  resources :customers, only: [] do
    resources :email_addresses,
      module: :customers,
      only: %i[index create destroy]
  end

  scope module: :invoice_sources do
    get "xero/connect", to: "xero_connections#new", as: :new_xero_connection
    get "xero/callback", to: "xero_connections#create", as: :xero_callback
    resource :xero_connection, controller: :xero_connections, only: :destroy

    get "stripe/connect", to: "stripe_connections#new", as: :new_stripe_connection
    get "stripe/callback", to: "stripe_connections#create", as: :stripe_callback
    resource :stripe_connection, controller: :stripe_connections, only: :destroy
  end

  scope module: :outbound_email_connections do
    get "gmail/connect", to: "gmail_connections#new", as: :new_gmail_connection
    get "gmail/callback", to: "gmail_connections#create", as: :gmail_callback
    resource :gmail_connection, controller: :gmail_connections, only: :destroy do
      post :test
    end
  end

  resources :invoice_sources, only: [] do
    scope module: :invoice_sources do
      resource :refresh, only: :create
    end
  end

  namespace :invoice_sources do
    namespace :webhooks do
      post :stripe, to: "stripe#create"
      post :xero, to: "xero#create"
    end
  end

  resource :signup, only: %i[new create] do
    collection do
      scope module: :signups, as: :signup do
        resource :completion, only: %i[new create]
      end
    end
  end

  resource :session, only: %i[new create destroy] do
    scope module: :sessions do
      resource :magic_link, only: %i[show create]
    end
  end

  namespace :account do
    resource :settings, only: %i[show update]
    resource :notification_preferences, only: :update
    resource :customer_segment_refresh, only: :create
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
