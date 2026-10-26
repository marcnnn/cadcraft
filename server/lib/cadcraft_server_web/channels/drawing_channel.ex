defmodule CADCraftServerWeb.DrawingChannel do
  @moduledoc """
  Live collaboration on one drawing, topic `drawing:<id>`.

  From the server: `committed` (revision, touched and deleted handles: pull those),
  `lease` / `lease_released` (who is editing which component), `cursor` (other users' cursors).

  From a client: `cursor` (relayed to the others), `lease:acquire`, `lease:release`, `commit`
  (the same Ash actions as the JSON API, with the socket's actor). Share links may join and
  follow, but every write is refused by the policies.
  """
  use Phoenix.Channel

  alias CADCraftServer.Design.{Drawing, Lease}

  @impl true
  def join("drawing:" <> id, _params, socket) do
    case Ash.get(Drawing, id, actor: socket.assigns.actor) do
      {:ok, drawing} -> {:ok, %{revision: drawing.revision}, assign(socket, :drawing_id, id)}
      _ -> {:error, %{reason: "not found"}}
    end
  end

  @impl true
  def handle_in("cursor", %{"x" => x, "y" => y}, socket) when is_number(x) and is_number(y) do
    broadcast_from!(socket, "cursor", %{user: actor_id(socket), x: x, y: y})
    {:noreply, socket}
  end

  def handle_in("lease:acquire", %{"comp" => comp} = p, socket),
    do: run(Lease, :acquire, %{comp: comp, duration_ms: p["duration_ms"] || 5_000}, socket)

  def handle_in("lease:release", %{"comp" => comp}, socket),
    do: run(Lease, :release, %{comp: comp}, socket)

  def handle_in("commit", p, socket) do
    args = %{
      base_revision: p["base_revision"],
      upserts: p["upserts"] || [],
      deletes: p["deletes"] || [],
      constraints: p["constraints"],
      parameters: p["parameters"]
    }

    run(Drawing, :commit, args, socket)
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "unknown event"}}, socket}

  defp run(resource, action, args, socket) do
    resource
    |> Ash.ActionInput.for_action(action, Map.put(args, :drawing_id, socket.assigns.drawing_id),
      actor: socket.assigns.actor
    )
    |> Ash.run_action()
    |> case do
      {:ok, result} -> {:reply, {:ok, result}, socket}
      {:error, %Ash.Error.Forbidden{}} -> {:reply, {:error, %{reason: "forbidden"}}, socket}
      {:error, e} -> {:reply, {:error, %{reason: Exception.message(e)}}, socket}
    end
  end

  defp actor_id(%{assigns: %{actor: %{id: id}}}), do: id
  defp actor_id(_), do: "share"
end
