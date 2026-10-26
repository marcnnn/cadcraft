defmodule CADCraftServerWeb.FallbackController do
  @moduledoc "Ash errors to HTTP: forbidden and not-found both answer 404, so a stranger learns nothing about what exists."
  use CADCraftServerWeb, :controller

  def call(conn, {:error, :bad_request}), do: reply(conn, 400, "bad request")

  def call(conn, {:error, %Ash.Error.Forbidden{}}), do: reply(conn, 404, "not found")

  def call(conn, {:error, %Ash.Error.Invalid{} = e}) do
    if Enum.any?(e.errors, &match?(%Ash.Error.Query.NotFound{}, &1)),
      do: reply(conn, 404, "not found"),
      else: reply(conn, 422, Exception.message(e))
  end

  # Commits and leases refuse with a plain message (stale, constraints not met, leased).
  def call(conn, {:error, %Ash.Error.Unknown{errors: errors} = e}) do
    case Enum.find_value(errors, fn err -> is_binary(Map.get(err, :error)) && err.error end) do
      nil -> reply(conn, 500, Exception.message(e))
      message -> reply(conn, 409, message)
    end
  end

  def call(conn, {:error, e}) when is_binary(e), do: reply(conn, 409, e)
  def call(conn, {:error, e}), do: reply(conn, 500, inspect(e))

  defp reply(conn, status, message),
    do: conn |> put_status(status) |> json(%{error: message})
end
