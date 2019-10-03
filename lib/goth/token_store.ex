defmodule Goth.TokenStore do
  @moduledoc """
  The `Goth.TokenStore` is a simple `GenServer` that manages storage and retrieval
  of tokens `Goth.Token`. When adding to the token store, it also queues tokens
  for a refresh before they expire: ten seconds before the token is set to expire,
  the `TokenStore` will call the API to get a new token and replace the expired
  token in the store.
  """

  use GenServer
  alias Goth.Token

  @ets_table :goth_token_store

  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :ets.new(@ets_table, [:named_table, :set, {:read_concurrency, true}])
    {:ok, state}
  end

  @doc ~S"""
  Store a token in the `TokenStore`. Upon storage, Goth will queue the token
  to be refreshed ten seconds before its expiration.
  """
  @spec store(Token.t()) :: pid
  def store(%Token{} = token), do: store(token.scope, token.sub, token)

  @spec store({String.t() | atom(), String.t()} | String.t(), Token.t()) :: pid()
  def store(scopes, %Token{} = token) when is_binary(scopes),
    do: store({:default, scopes}, token.sub, token)

  def store({account, scopes}, %Token{} = token) when is_binary(scopes),
    do: store({account, scopes}, token.sub, token)

  @spec store(String.t(), String.t(), Token.t()) :: pid
  def store(scopes, sub, %Token{} = token) when is_binary(scopes),
    do: store({:default, scopes}, sub, token)

  @spec store({String.t() | atom(), String.t()}, String.t() | nil, Token.t()) :: pid
  def store({account, scopes}, sub, %Token{} = token) when is_binary(scopes) do
    GenServer.call(__MODULE__, {:store, {account, scopes, sub}, token})
  end

  @doc ~S"""
  Retrieve a token from the `TokenStore`.

      token = %Goth.Token{type:    "Bearer",
                          token:   "123",
                          scope:   "scope",
                          expires: :os.system_time(:seconds) + 3600}
      Goth.TokenStore.store(token)
      {:ok, ^token} = Goth.TokenStore.find(token.scope)
  """
  @spec find({String.t() | atom(), String.t()} | String.t(), String.t() | nil) ::
          {:ok, Token.t()} | :error
  def find(info, sub \\ nil)

  def find(scope, sub) when is_binary(scope), do: find({:default, scope}, sub)

  def find({account, scope}, sub) do
    case :ets.lookup(@ets_table, {account, scope, sub}) do
      [{{^account, ^scope, ^sub}, token}] ->
        case {:ok, token} |> filter_expired(:os.system_time(:seconds)) do
          :error -> GenServer.call(__MODULE__, {:find, {account, scope, sub}})
          response -> response
        end

      _ ->
        GenServer.call(__MODULE__, {:find, {account, scope, sub}})
    end
  end

  # when we store a token, we should refresh it later
  def handle_call({:store, {account, scope, sub}, token}, _from, state) do
    # this is a race condition when inserting an expired (or about to expire) token...
    :ets.insert(@ets_table, {{account, scope, sub}, token})
    pid_or_timer = Token.queue_for_refresh(token)
    {:reply, pid_or_timer, Map.put(state, {account, scope, sub}, token)}
  end

  def handle_call({:find, {account, scope, sub}}, _from, state) do
    state
    |> Map.fetch({account, scope, sub})
    |> filter_expired(:os.system_time(:seconds))
    |> reply(state, {account, scope, sub})
  end

  defp filter_expired(:error, _), do: :error

  defp filter_expired({:ok, %Goth.Token{expires: expires}}, system_time)
       when expires < system_time,
       do: :error

  defp filter_expired(value, _), do: value

  defp reply(:error, state, {account, scope, sub}),
    do: {:reply, :error, Map.delete(state, {account, scope, sub})}

  defp reply(value, state, _key), do: {:reply, value, state}
end
