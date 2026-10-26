defmodule CADCraftServer.Checks.UserActor do
  @moduledoc "The actor is a signed-in user."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "actor is a user"

  @impl true
  def match?(%CADCraftServer.Accounts.User{}, _context, _opts), do: true
  def match?(_, _, _), do: false
end

defmodule CADCraftServer.Checks.ShareActor do
  @moduledoc "The actor is a share link."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "actor is a share link"

  @impl true
  def match?(%CADCraftServer.Design.ShareGrant{}, _context, _opts), do: true
  def match?(_, _, _), do: false
end

defmodule CADCraftServer.Checks.ProjectRole do
  @moduledoc """
  The actor has one of `roles` in the project a create or a generic action targets.

  Filter checks (`expr(exists(project.memberships, ...))`) cover reads, updates and destroys,
  where the record exists. A create or an action input has no record yet, so this check looks
  the project up from the input: `project: :project_id` reads the project id directly,
  `drawing: :drawing_id` goes through the drawing.
  """
  use Ash.Policy.SimpleCheck
  import Ecto.Query

  alias CADCraftServer.Repo

  @impl true
  def describe(opts), do: "actor is #{Enum.join(opts[:roles], " or ")} of the project"

  @impl true
  def match?(%CADCraftServer.Accounts.User{id: user_id}, context, opts) do
    roles = Enum.map(opts[:roles], &to_string/1)

    case project_id(context, opts) do
      nil ->
        false

      project_id ->
        from(m in "memberships",
          where:
            m.project_id == type(^project_id, Ecto.UUID) and
              m.user_id == type(^user_id, Ecto.UUID) and m.role in ^roles
        )
        |> Repo.exists?()
    end
  end

  def match?(_, _, _), do: false

  defp project_id(context, opts) do
    cond do
      field = opts[:project] ->
        input(context, field)

      field = opts[:drawing] ->
        case input(context, field) do
          nil ->
            nil

          drawing_id ->
            from(d in "cad_drawings",
              where: d.id == type(^drawing_id, Ecto.UUID),
              select: type(d.project_id, Ecto.UUID)
            )
            |> Repo.one()
        end
    end
  end

  defp input(%{changeset: %Ash.Changeset{} = cs}, field),
    do: Ash.Changeset.get_attribute(cs, field) || Ash.Changeset.get_argument(cs, field)

  defp input(%{action_input: %Ash.ActionInput{} = input}, field),
    do: Ash.ActionInput.get_argument(input, field)

  defp input(_, _), do: nil
end
