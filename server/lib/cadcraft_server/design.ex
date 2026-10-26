defmodule CADCraftServer.Design do
  @moduledoc """
  Projects, their members and share links, and the drawings they hold.

  A drawing's entities, constraints and parameters are written only by `commit` (see
  `CADCraftServer.Design.Commit`): CADCraft solves, the server checks the result with
  CADCraft's own code and stores it. Everything else here is read access, and every read goes
  through the policies, so the same rules hold for the JSON API, the channel and vector tiles.
  """
  use Ash.Domain

  resources do
    resource(CADCraftServer.Design.Project)
    resource(CADCraftServer.Design.Membership)
    resource(CADCraftServer.Design.ShareLink)
    resource(CADCraftServer.Design.Drawing)
    resource(CADCraftServer.Design.Entity)
    resource(CADCraftServer.Design.Constraint)
    resource(CADCraftServer.Design.Parameter)
    resource(CADCraftServer.Design.Lease)
    resource(CADCraftServer.Design.Revision)
  end
end
