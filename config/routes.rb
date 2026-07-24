Rails.application.routes.draw do
  draw :madmin
  root "landing#index"
  get "privacy", to: "pages#privacy", as: :privacy
  get "terms", to: "pages#terms", as: :terms

  get "signup/xero", to: "xero/signups#new", as: :new_xero_signup
  get "signup/xero/callback", to: "xero/signups#create", as: :xero_signup_callback
  get "session/xero", to: "xero/sessions#new", as: :new_xero_session
  get "session/xero/callback", to: "xero/sessions#create", as: :xero_session_callback

  resources :invoices, only: :index
  resources :conversations, only: %i[index show] do
    scope module: :conversations do
      resource :match, only: %i[new create]
      resources :reviews, only: :update, param: :message_id
      resources :replies, only: :create
      resource :acknowledgement, only: :create
      resources :actions, only: [] do
        scope module: :actions do
          resources :revisions, only: :create
          resource :approval, only: :create
          resource :rejection, only: :create
        end
      end
      resources :collection_holds, only: :create do
        scope module: :collection_holds do
          resource :release, only: :create
        end
      end
      resources :escalations, only: :create do
        scope module: :escalations do
          resource :resolution, only: :create
          resource :reopening, only: :create
        end
      end
    end
  end
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
  end

  namespace :stripe_app, path: "stripe/app" do
    resources :onboarding_claims, only: :create
    match "onboarding_claims", to: "onboarding_claims#preflight", via: :options
    resource :onboarding, only: %i[show update]
  end

  scope module: :email_connections do
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
      post :stripe, to: "stripe#create", defaults: { webhook_mode: "live" }
      post "stripe/test", to: "stripe#create", as: :stripe_test, defaults: { webhook_mode: "test" }
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
