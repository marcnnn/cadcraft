defmodule CADCraftServerWeb.UserSocket do
  use Phoenix.Socket

  channel "drawing:*", CADCraftServerWeb.DrawingChannel

  # Connect with `?token=<user token>` or `?share=<share token>`.
  @impl true
  def connect(params, socket, _connect_info) do
    actor =
      cond do
        token = params["token"] -> CADCraftServerWeb.Plugs.Actor.user(token)
        token = params["share"] -> CADCraftServerWeb.Plugs.Actor.share(token)
        true -> nil
      end

    if actor, do: {:ok, assign(socket, :actor, actor)}, else: :error
  end

  @impl true
  def id(_socket), do: nil
end
