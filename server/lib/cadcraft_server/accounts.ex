defmodule CADCraftServer.Accounts do
  @moduledoc """
  Who is asking. Users carry an API token (stored hashed); a share link stands in for a user
  when a project is shared outside its members.

  This is the smallest thing that works for trying the server out. A real deployment swaps the
  token for `ash_authentication` (password, magic link, OIDC) without touching the design domain:
  its policies only look at the actor.
  """
  use Ash.Domain

  resources do
    resource(CADCraftServer.Accounts.User)
  end
end
