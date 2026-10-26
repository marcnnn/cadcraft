defmodule CADCraftServer.Design.Events do
  @moduledoc """
  Drawing events go out on the PubSub topic `drawing:<id>`, which is also the channel topic,
  so every client in the drawing's channel gets them without the domain knowing about sockets.
  """

  def topic(drawing_id), do: "drawing:#{drawing_id}"

  def broadcast(drawing_id, event, payload) do
    Phoenix.PubSub.broadcast(
      CADCraftServer.PubSub,
      topic(drawing_id),
      %Phoenix.Socket.Broadcast{topic: topic(drawing_id), event: event, payload: payload}
    )
  end
end
