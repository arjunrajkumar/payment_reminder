Rails.application.routes.draw do
  root "landing#index"
  get "/home", to: "receivables#index", as: :home

  scope module: :invoice_sources do
    get "xero/connect", to: "xero_connections#new", as: :new_xero_connection
    get "xero/callback", to: "xero_connections#create", as: :xero_callback
    resource :xero_connection, controller: :xero_connections, only: :destroy

    get "stripe/connect", to: "stripe_connections#new", as: :new_stripe_connection
    get "stripe/callback", to: "stripe_connections#create", as: :stripe_callback
    resource :stripe_connection, controller: :stripe_connections, only: :destroy
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

  get "/customers", to: redirect { |_params, request| "#{request.script_name}/home" }, as: :customers
  resources :customers, only: :show

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
    resource :settings, only: :show
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
