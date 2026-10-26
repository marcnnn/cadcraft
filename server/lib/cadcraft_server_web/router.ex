defmodule CADCraftServerWeb.Router do
  use CADCraftServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug CADCraftServerWeb.Plugs.Actor
  end

  pipeline :tiles do
    plug CADCraftServerWeb.Plugs.Actor
  end

  scope "/api", CADCraftServerWeb do
    pipe_through :api

    post "/users", ApiController, :register
    post "/projects", ApiController, :create_project
    post "/projects/:project_id/members", ApiController, :add_member
    post "/projects/:project_id/share_links", ApiController, :create_share_link
    post "/projects/:project_id/drawings", ApiController, :create_drawing
    get "/drawings/:id", ApiController, :show_drawing
    get "/drawings/:id/entities", ApiController, :entities
    post "/drawings/:id/commit", ApiController, :commit
    post "/drawings/:id/leases/:comp", ApiController, :acquire_lease
    delete "/drawings/:id/leases/:comp", ApiController, :release_lease
  end

  scope "/tiles", CADCraftServerWeb do
    pipe_through :tiles
    get "/:drawing_id/:z/:x/:y", TileController, :show
  end
end
