defmodule CADCraftServerWeb.Plugs.Actor do
  @moduledoc """
  Sets the Ash actor from the request: a user API token (`Authorization: Bearer <token>`) or a
  share link token (`?share=<token>` or `X-Share-Token`). No token: no actor, and the policies
  refuse everything that needs one.
  """
  import Plug.Conn

  alias CADCraftServer.Accounts.User
  alias CADCraftServer.Design.ShareLink

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    actor =
      cond do
        token = bearer(conn) -> user(token)
        token = share_token(conn) -> share(token)
        true -> nil
      end

    Ash.PlugHelpers.set_actor(conn, actor)
  end

  @doc "The actor for a token, as used by the plug and the socket."
  def user(token) do
    case User |> Ash.Query.for_read(:by_token, %{token: token}) |> Ash.read_one() do
      {:ok, %User{} = user} -> user
      _ -> nil
    end
  end

  def share(token) do
    case ShareLink |> Ash.Query.for_read(:grant, %{token: token}) |> Ash.read_one() do
      {:ok, %ShareLink{} = link} -> ShareLink.to_grant(link)
      _ -> nil
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> nil
    end
  end

  defp share_token(conn) do
    conn.query_params["share"] || List.first(get_req_header(conn, "x-share-token"))
  end
end
