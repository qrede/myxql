defmodule MyXQL do
  def start_link(opts) do
    DBConnection.start_link(MyXQL.Protocol, opts)
  end

  def query(conn, statement, params \\ [], opts \\ []) do
    query_type = Keyword.get(opts, :query_type, :binary)
    query = %MyXQL.Query{name: "", ref: make_ref(), statement: statement, type: query_type}

    case query_type do
      :binary ->
        with {:ok, _query, result} <- DBConnection.prepare_execute(conn, query, params, opts) do
          {:ok, result}
        end

      :text ->
        with {:ok, _query, result} <- DBConnection.execute(conn, query, params, opts) do
          {:ok, result}
        end
    end
  end

  def query!(conn, statement, params \\ [], opts \\ []) do
    case query(conn, statement, params, opts) do
      {:ok, result} -> result
      {:error, exception} -> raise exception
    end
  end

  def prepare(conn, name, statement, opts \\ []) do
    query = %MyXQL.Query{name: name, statement: statement, ref: make_ref()}
    DBConnection.prepare(conn, query, opts)
  end

  def prepare_execute(conn, name, statement, params \\ [], opts \\ [])
      when is_binary(statement) do
    query = %MyXQL.Query{name: name, statement: statement, ref: make_ref()}

    case DBConnection.prepare_execute(conn, query, params, opts) do
      {:ok, query, result} ->
        {:ok, query, result}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defdelegate execute(conn, query, params \\ [], opts \\ []), to: DBConnection

  defdelegate transaction(conn, fun, opts \\ []), to: DBConnection

  defdelegate rollback(conn, reason), to: DBConnection

  def child_spec(opts) do
    DBConnection.child_spec(MyXQL.Protocol, opts)
  end
end
