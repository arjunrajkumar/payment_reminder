Rails.application.routes.draw do
  root "landing#index"
  get "/home", to: "landing#index", as: :home

  scope module: :invoice_sources do
    get "xero/connect", to: "xero_connections#new", as: :new_xero_connection
    get "xero/callback", to: "xero_connections#create", as: :xero_callback
    resource :xero_connection, controller: :xero_connections, only: %i[show destroy]

    get "stripe/connect", to: "stripe_connections#new", as: :new_stripe_connection
    get "stripe/callback", to: "stripe_connections#create", as: :stripe_callback
    resource :stripe_connection, controller: :stripe_connections, only: %i[show destroy]
  end

  resources :invoice_sources, only: :index
  resources :invoices, only: :index

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
  end

  resources :users, only: %i[show destroy] do
    scope module: :users do
      resource :role, only: :update
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
