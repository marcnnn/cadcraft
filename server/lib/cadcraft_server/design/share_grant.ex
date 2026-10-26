defmodule CADCraftServer.Design.ShareGrant do
  @moduledoc """
  The actor for a request made with a share link instead of a user token: read-only access to
  one project, without the layers the link hides and without the parametric recipe
  (constraints and parameters).
  """
  defstruct [:share_project_id, :link_id, hidden_layers: []]
end
