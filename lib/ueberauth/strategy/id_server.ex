defmodule Ueberauth.Strategy.IdServer do
  @moduledoc """
  Provides an Ueberauth strategy for authenticating with IdServer.
  ### Setup
  Create an application in IdServer for you to use.
  Register a new application at: [your id_server developer page](https://id_server.com/settings/developers) and get the `client_id` and `client_secret`.
  Include the provider in your configuration for Ueberauth
      config :ueberauth, Ueberauth,
        providers: [
          id_server: { Ueberauth.Strategy.IdServer, [] }
        ]
  Then include the configuration for id_server.
      config :ueberauth, Ueberauth.Strategy.IdServer.OAuth,
        client_id: System.get_env("GITHUB_CLIENT_ID"),
        client_secret: System.get_env("GITHUB_CLIENT_SECRET")
  If you haven't already, create a pipeline and setup routes for your callback handler
      pipeline :auth do
        Ueberauth.plug "/auth"
      end
      scope "/auth" do
        pipe_through [:browser, :auth]
        get "/:provider/callback", AuthController, :callback
      end
  Create an endpoint for the callback where you will handle the `Ueberauth.Auth` struct
      defmodule MyApp.AuthController do
        use MyApp.Web, :controller
        def callback_phase(%{ assigns: %{ ueberauth_failure: fails } } = conn, _params) do
          # do things with the failure
        end
        def callback_phase(%{ assigns: %{ ueberauth_auth: auth } } = conn, params) do
          # do things with the auth
        end
      end
  You can edit the behaviour of the Strategy by including some options when you register your provider.
  To set the `uid_field`
      config :ueberauth, Ueberauth,
        providers: [
          id_server: { Ueberauth.Strategy.IdServer, [uid_field: :email] }
        ]
  Default is `:id`
  To set the default 'scopes' (permissions):
      config :ueberauth, Ueberauth,
        providers: [
          id_server: { Ueberauth.Strategy.IdServer, [default_scope: "user,public_repo"] }
        ]
  Default is empty ("") which "Grants read-only access to public information (includes public user profile info, public repository info, and gists)"
  """
  use Ueberauth.Strategy,
    uid_field: :id,
    default_scope: "",
    oauth2_module: Ueberauth.Strategy.IdServer.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles the initial redirect to the id_server authentication page.
  To customize the scope (permissions) that are requested by id_server include them as part of your url:
      "/auth/id_server?scope=user,public_repo,gist"
  You can also include a `state` param that id_server will return to you.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)
    send_redirect_uri = Keyword.get(options(conn), :send_redirect_uri, true)

    opts =
      if send_redirect_uri do
        [redirect_uri: callback_url(conn), scope: scopes]
      else
        [scope: scopes]
      end

    opts =
      if conn.params["state"], do: Keyword.put(opts, :state, conn.params["state"]), else: opts

    module = option(conn, :oauth2_module)
    redirect!(conn, apply(module, :authorize_url!, [opts]))
  end

  @doc """
  Handles the callback from IdServer. When there is a failure from IdServer the failure is included in the
  `ueberauth_failure` struct. Otherwise the information returned from IdServer is returned in the `Ueberauth.Auth` struct.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    module = option(conn, :oauth2_module)
    token = apply(module, :get_token!, [[code: code]])

    if token.access_token == nil do
      set_errors!(conn, [
        error(token.other_params["error"], token.other_params["error_description"])
      ])
    else
      fetch_user(conn, token)
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc """
  Cleans up the private area of the connection used for passing the raw IdServer response around during the callback.
  """
  def handle_cleanup!(conn) do
    conn
    |> put_private(:id_server_user, nil)
    |> put_private(:id_server_token, nil)
  end

  @doc """
  Fetches the uid field from the IdServer response. This defaults to the option `uid_field` which in-turn defaults to `id`
  """
  def uid(conn) do
    conn |> option(:uid_field) |> to_string() |> fetch_uid(conn)
  end

  @doc """
  Includes the credentials from the IdServer response.
  """
  def credentials(conn) do
    token = conn.private.id_server_token
    scope_string = token.other_params["scope"] || ""
    scopes = String.split(scope_string, ",")

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: token.expires_at,
      token_type: token.token_type,
      expires: !!token.expires_at,
      scopes: scopes
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.id_server_user
    allow_private_emails = Keyword.get(options(conn), :allow_private_emails, false)

    %Info{
      name: user["name"],
      description: user["bio"],
      nickname: user["login"],
      email: fetch_email!(user, allow_private_emails),
      location: user["location"],
      image: user["avatar_url"],
      urls: %{
        followers_url: user["followers_url"],
        avatar_url: user["avatar_url"],
        events_url: user["events_url"],
        starred_url: user["starred_url"],
        blog: user["blog"],
        subscriptions_url: user["subscriptions_url"],
        organizations_url: user["organizations_url"],
        gists_url: user["gists_url"],
        following_url: user["following_url"],
        api_url: user["url"],
        html_url: user["html_url"],
        received_events_url: user["received_events_url"],
        repos_url: user["repos_url"]
      }
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from the IdServer callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.id_server_token,
        user: conn.private.id_server_user
      }
    }
  end

  defp fetch_uid("email", conn) do
    # private email will not be available as :email and must be fetched
    allow_private_emails = Keyword.get(options(conn), :allow_private_emails, false)
    fetch_email!(conn.private.id_server_user.user, allow_private_emails)
  end

  defp fetch_uid(field, conn) do
    conn.private.id_server_user[field]
  end

  defp fetch_email!(user, allow_private_emails) do
    user["email"] ||
      get_primary_email!(user) ||
      get_private_email!(user, allow_private_emails) ||
      raise "Unable to access the user's email address"
  end

  defp get_primary_email!(user) do
    if user["emails"] && Enum.count(user["emails"]) > 0 do
      Enum.find(user["emails"], & &1["primary"])["email"]
    end
  end

  defp get_private_email!(user, allow_private_emails) do
    if allow_private_emails do
      "#{user["id"]}+#{user["login"]}@users.noreply.id_server.com"
    end
  end

  defp fetch_user(conn, token) do
    conn = put_private(conn, :id_server_token, token)
    # Will be better with Elixir 1.3 with/else
    case Ueberauth.Strategy.IdServer.OAuth.get(token, "/user") do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])

      {:ok, %OAuth2.Response{status_code: status_code, body: user}}
      when status_code in 200..399 ->
        case Ueberauth.Strategy.IdServer.OAuth.get(token, "/user/emails") do
          {:ok, %OAuth2.Response{status_code: status_code, body: emails}}
          when status_code in 200..399 ->
            user = Map.put(user, "emails", emails)
            put_private(conn, :id_server_user, user)

          # Continue on as before
          {:error, _} ->
            put_private(conn, :id_server_user, user)
        end

      {:error, %OAuth2.Error{reason: reason}} ->
        set_errors!(conn, [error("OAuth2", reason)])

      {:error, %OAuth2.Response{body: %{"message" => reason}}} ->
        set_errors!(conn, [error("OAuth2", reason)])

      {:error, _} ->
        set_errors!(conn, [error("OAuth2", "uknown error")])
    end
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end
end
