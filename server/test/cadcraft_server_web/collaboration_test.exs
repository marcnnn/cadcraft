defmodule CADCraftServerWeb.CollaborationTest do
  @moduledoc """
  The whole loop over HTTP against PostGIS: a project with roles, constrained commits checked by
  CADCraft's own code, stale and leased commits refused, a share link that hides a layer, and
  vector tiles only for those allowed to see the drawing.
  """
  use CADCraftServerWeb.ConnCase, async: true

  @layer "A-WALL"

  defp line(handle, {ax, ay}, {bx, by}, layer \\ @layer) do
    %{
      "handle" => handle,
      "common" => %{"layer" => layer},
      "kind" => %{
        "type" => "line",
        "a" => %{"x" => ax, "y" => ay, "z" => 0.0},
        "b" => %{"x" => bx, "y" => by, "z" => 0.0}
      }
    }
  end

  # Lines 0x100 and 0x101 meet at a corner; 0x200 is a lone line on a layer the share link hides.
  @corner %{
    "id" => 1,
    "kind" => "coincident",
    "refs" => [
      %{"handle" => 256, "sub" => %{"kind" => "end"}},
      %{"handle" => 257, "sub" => %{"kind" => "start"}}
    ],
    "name" => "",
    "expr" => ""
  }

  defp user(conn, email) do
    token = "token-" <> email
    conn |> post("/api/users", %{email: email, token: token}) |> json_response(200)

    %{
      token: token,
      id:
        Ash.read_one!(
          CADCraftServer.Accounts.User
          |> Ash.Query.for_read(:by_token, %{token: token})
        ).id
    }
  end

  defp as(conn, %{token: t}), do: put_req_header(conn, "authorization", "Bearer " <> t)

  setup %{conn: conn} do
    owner = user(conn, "owner@example.com")
    editor = user(conn, "editor@example.com")
    viewer = user(conn, "viewer@example.com")
    stranger = user(conn, "stranger@example.com")

    %{"id" => project} =
      build_conn()
      |> as(owner)
      |> post("/api/projects", %{name: "Riverside"})
      |> json_response(200)

    for {u, role} <- [{editor, "editor"}, {viewer, "viewer"}] do
      build_conn()
      |> as(owner)
      |> post("/api/projects/#{project}/members", %{user_id: u.id, role: role})
      |> json_response(200)
    end

    # Drawing metres placed at the origin of Web Mercator: tile 16/32768/32767 (611 m wide,
    # north-east of the origin) holds them.
    %{"id" => drawing} =
      build_conn()
      |> as(owner)
      |> post("/api/projects/#{project}/drawings", %{name: "Ground floor", srid: 3857})
      |> json_response(200)

    %{
      owner: owner,
      editor: editor,
      viewer: viewer,
      stranger: stranger,
      project: project,
      drawing: drawing
    }
  end

  defp commit(user, drawing, body),
    do: build_conn() |> as(user) |> post("/api/drawings/#{drawing}/commit", body)

  defp first_commit(%{editor: editor, drawing: drawing}) do
    commit(editor, drawing, %{
      base_revision: 0,
      upserts: [
        line(256, {0.0, 0.0}, {10.0, 0.0}),
        line(257, {10.0, 0.0}, {10.0, 8.0}),
        line(512, {50.0, 0.0}, {60.0, 0.0}, "X-SECRET")
      ],
      constraints: [@corner]
    })
  end

  test "an editor's solved commit is stored with PostGIS geometry and broadcast", ctx do
    CADCraftServerWeb.Endpoint.subscribe("drawing:#{ctx.drawing}")
    assert %{"revision" => 1, "touched" => touched} = first_commit(ctx) |> json_response(200)
    assert Enum.sort(touched) == ["100", "101", "200"]
    assert_receive %Phoenix.Socket.Broadcast{event: "committed", payload: %{revision: 1}}

    %{rows: rows} =
      CADCraftServer.Repo.query!(
        "SELECT handle, comp, ST_GeometryType(exact), ST_SRID(tile_geom), tags->>'layer' FROM cad_entities ORDER BY handle"
      )

    assert rows == [
             ["100", "100", "ST_LineString", 3857, @layer],
             ["101", "100", "ST_LineString", 3857, @layer],
             ["200", nil, "ST_LineString", 3857, "X-SECRET"]
           ]
  end

  test "commits that break a constraint, are stale, or come from a viewer are refused", ctx do
    assert json_response(first_commit(ctx), 200)

    # Only one side of the corner moved: the coincidence no longer holds.
    broken = %{base_revision: 1, upserts: [line(256, {0.0, 0.0}, {12.0, 0.0})]}

    assert %{"error" => "constraints not met" <> _} =
             commit(ctx.editor, ctx.drawing, broken) |> json_response(409)

    # Both sides moved together: fine, but not against an old revision.
    solved = %{
      base_revision: 1,
      upserts: [line(256, {0.0, 0.0}, {12.0, 0.0}), line(257, {12.0, 0.0}, {10.0, 8.0})]
    }

    stale = %{solved | base_revision: 0}

    assert %{"error" => "stale" <> _} =
             commit(ctx.editor, ctx.drawing, stale) |> json_response(409)

    assert json_response(commit(ctx.viewer, ctx.drawing, solved), 404)
    assert json_response(commit(ctx.stranger, ctx.drawing, solved), 404)
    assert %{"revision" => 2} = commit(ctx.editor, ctx.drawing, solved) |> json_response(200)
  end

  test "a component leased by someone else cannot be committed to until released", ctx do
    assert json_response(first_commit(ctx), 200)
    lease = "/api/drawings/#{ctx.drawing}/leases/100"

    assert json_response(build_conn() |> as(ctx.viewer) |> post(lease), 404)
    assert %{"comp" => "100"} = build_conn() |> as(ctx.owner) |> post(lease) |> json_response(200)
    assert %{"error" => _} = build_conn() |> as(ctx.editor) |> post(lease) |> json_response(409)

    solved = %{
      base_revision: 1,
      upserts: [line(256, {0.0, 0.0}, {12.0, 0.0}), line(257, {12.0, 0.0}, {10.0, 8.0})]
    }

    assert %{"error" => "leased" <> _} =
             commit(ctx.editor, ctx.drawing, solved) |> json_response(409)

    # The unconstrained line is in no component: no lease needed.
    free = %{base_revision: 1, upserts: [line(512, {50.0, 1.0}, {60.0, 1.0}, "X-SECRET")]}
    assert %{"revision" => 2} = commit(ctx.editor, ctx.drawing, free) |> json_response(200)

    assert json_response(build_conn() |> as(ctx.owner) |> delete(lease), 200)

    assert %{"revision" => 3} =
             commit(ctx.editor, ctx.drawing, %{solved | base_revision: 2}) |> json_response(200)
  end

  test "a share link sees the drawing without hidden layers and without the recipe", ctx do
    assert json_response(first_commit(ctx), 200)

    %{"token" => share} =
      build_conn()
      |> as(ctx.owner)
      |> post("/api/projects/#{ctx.project}/share_links", %{hidden_layers: ["X-SECRET"]})
      |> json_response(200)

    assert json_response(
             build_conn()
             |> as(ctx.editor)
             |> post("/api/projects/#{ctx.project}/share_links", %{}),
             404
           )

    entities =
      build_conn()
      |> get("/api/drawings/#{ctx.drawing}/entities", %{bbox: "-100,-100,100,100", share: share})
      |> json_response(200)

    assert Enum.map(entities, & &1["handle"]) |> Enum.sort() == ["100", "101"]

    # Constraints are the recipe: members read them, share links are refused outright.
    grant = CADCraftServerWeb.Plugs.Actor.share(share)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.read(CADCraftServer.Design.Constraint, actor: grant)

    viewer = Ash.get!(CADCraftServer.Accounts.User, ctx.viewer.id, authorize?: false)
    assert {:ok, [_]} = Ash.read(CADCraftServer.Design.Constraint, actor: viewer)

    assert json_response(commit(%{token: "nope"}, ctx.drawing, %{base_revision: 1}), 404)

    assert build_conn()
           |> get("/api/drawings/#{ctx.drawing}/entities", %{bbox: "0,0,1,1", share: "wrong"})
           |> json_response(404)
  end

  test "vector tiles are served to members and refused to strangers", ctx do
    assert json_response(first_commit(ctx), 200)

    path = "/tiles/#{ctx.drawing}/16/32768/32767.mvt"
    tile = build_conn() |> as(ctx.viewer) |> get(path)
    assert tile.status == 200
    assert ["application/vnd.mapbox-vector-tile" <> _] = get_resp_header(tile, "content-type")
    assert byte_size(tile.resp_body) > 0
    assert tile.resp_body =~ "cad"

    # A tile elsewhere is empty; a tile that cannot exist is not found.
    assert build_conn()
           |> as(ctx.viewer)
           |> get("/tiles/#{ctx.drawing}/16/0/0.mvt")
           |> response(200) == ""

    assert build_conn()
           |> as(ctx.viewer)
           |> get("/tiles/#{ctx.drawing}/1/5/0.mvt")
           |> response(404)

    assert build_conn() |> as(ctx.stranger) |> get(path) |> response(404)
  end
end
