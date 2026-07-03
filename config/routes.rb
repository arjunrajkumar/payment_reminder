Rails.application.routes.draw do
  root "landing#index"
  get "/home", to: "landing#index", as: :home
  get "/xero/connect", to: "xero_connections#new", as: :new_xero_connection
  get "/xero/callback", to: "xero_connections#create", as: :xero_callback
  resource :xero_connection, only: %i[show destroy]

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
