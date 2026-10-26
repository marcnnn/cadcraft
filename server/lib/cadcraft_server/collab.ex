defmodule CADCraftServer.Collab do
  @moduledoc """
  CADCraft's own code, in the server: `cadcraft-collab` (crates/collab) through a Rustler NIF.

    * `snapshot/2` - drawing parts (CADCraft JSON) to the rows the server stores: exact and
      flattened geometry as WKT, the constraint component of each entity
    * `check/2` - whether a commit's solved geometry still meets every constraint, whether a
      Fix moved, and which entities and components it touched
  """
  use Rustler, otp_app: :cadcraft_server, crate: "cadcraft_collab_nif"

  def snapshot(_parts_json, _tolerance), do: :erlang.nif_error(:nif_not_loaded)
  def check(_before_json, _after_json), do: :erlang.nif_error(:nif_not_loaded)
end
